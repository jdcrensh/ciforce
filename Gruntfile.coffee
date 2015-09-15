fs = require 'fs-extra'
glob = require 'glob'
minimatch = require 'minimatch'
async = require 'async'
AdmZip = require 'adm-zip'
Git = require 'simple-git'
jsforce = require 'jsforce'
DOMParser = require('xmldom').DOMParser
xpath = require 'xpath'
pd = require('pretty-data').pd
_ = require 'lodash'

module.exports = (grunt) ->
  sfdc = null
  instances = {}

  require('time-grunt') grunt
  require('load-grunt-tasks') @

  pkg = @file.readJSON 'package.json'
  
  conf =
    git:
      config:
        push: default: 'simple'
        user:
          name: @option 'git-name'
          email: @option 'git-email'
      ref: @option 'git-ref'
      url: @option 'git-url'
      branch: @option 'git-branch'
      commitmsg: @option 'git-commitmsg'
      dryrun: @option('git-dryrun') ? false
      tagref: @option('git-tagref') ? true

    sfdc:
      sandbox: @option 'sf-sandbox'
      username: @option 'sf-username'
      password: @option 'sf-password'
      securitytoken: @option 'sf-securitytoken'
      deployRequestId: @option 'sf-deployrequestid'
      version: pkg.sfdc.version
      checkOnly: pkg.sfdc.checkOnly
      allowMissingFiles: pkg.sfdc.allowMissingFiles
      ignoreWarnings: pkg.sfdc.ignoreWarnings
      maxPoll: pkg.sfdc.maxPoll
      pollWaitMillis: pkg.sfdc.pollWaitMillis
      testReportsDir: pkg.sfdc.testReportsDir
      fullDeploy: pkg.sfdc.fullDeploy
      undeployMissing: pkg.sfdc.undeployMissing
      metadata:
        include: types: @option('metadata-includes')?.split(',') ? @file.read('metadata-types.txt').split /\r?\n/
        exclude: types: (@option('metadata-excludes') ? '').split ','

  # init configuration
  @initConfig 
    pkg: pkg
    git: options: conf.git
    sfdc: options: conf.sfdc
    clean: pkg: 'pkg', repo: 'repo'
  
  # init metadata component excludes
  excludes = pkg.defaultExcludes
  @config('sfdc.options.metadata.include.types').forEach (type) =>
    if (val = @option "#{type}-excludes")? or val is ''
      excludes[type] = val?.split ','
  @config 'sfdc.options.metadata.exclude.components', excludes

  # simple async error reporting
  handleError = (err, done) ->
    grunt.log.error()
    grunt.fatal err
    done false

  # runs a task target given a task class instance
  runTask = (instance) ->
    fn = if (target = @args[0])? then instance[target] else instance.default
    do _.bind (fn ? badTarget), @
    
  badTarget = ->
    grunt.warn if (target = @args[0])?
      "#{@name}: target not defined for this task (#{target})"
    else
      "#{@name}: default target not defined for this task"

  # convenience mixin for registering a task
  registerTask = (name, clazz) ->
    grunt.registerTask name, -> _.bind(runTask, @)(instances[@name] ?= new clazz())

  class GitTask
    registerTask 'git', @

    repo: ->
      @requiresConfig 'git.options.config.user.name',
        'git.options.config.user.email', 'git.options.url', 'git.options.branch'
      done = @async()

      fs.ensureDir 'repo'
      git = new Git 'repo'

      git_run = (cmd) -> (callback) -> 
        grunt.log.subhead "git #{cmd}"
        git._run cmd, (err, res) ->
          return handleError err, callback if err
          grunt.log.ok 'OK'
          callback()

      git._run 'config remote.origin.url', (err, url) ->
        return handleError err, done if err
        url = _.trim url

        git.outputHandler (cmd, stdout, stderr) ->
          stdout.on 'data', (buf) -> grunt.log.writeln _.trim buf
          stderr.on 'data', (buf) -> grunt.log.writeln _.trim buf

        if url is conf.git.url 
          async.series [
            git_run 'fetch --all --tags'
            git_run "checkout -f #{conf.git.branch}"
            git_run "reset --hard origin/#{conf.git.branch}"
            git_run 'clean -fd'
          ], -> done()
        else
          grunt.file.delete 'repo'
          git._baseDir = null
          git._run "clone --branch=#{conf.git.branch} #{conf.git.url} repo", ->
            git._baseDir = 'repo'
            done()

    pkg: ->
      @requires ['git:repo']
      done = @async()

      namespace = 'http://soap.sforce.com/2006/04/metadata'
      pkg_tmpl = "<Package xmlns=\"#{namespace}\"><version>#{sfdc.version}</version></Package>"

      git = new Git 'repo'

      diff_tree = (filter, ref1, ref2) ->
        "diff-tree -r --no-commit-id --name-only --minimal --diff-filter=#{filter} #{ref1} #{ref2}"

      describeByDir = conf.sfdc.describeByDir
      describeByName = conf.sfdc.describeByName

      groupByType = (path) ->
        dir = path[0...path.indexOf '/']
        describeByDir[dir].xmlName

      trimNames = (result, list, name) ->
        describe = describeByName[name]
        result[name] = list.map (path) ->
          path = path.substring 1 + path.indexOf '/'
          # remove file ext from path
          if (suffix = describe.suffix)?
            path = path[0...path.lastIndexOf(suffix) - 1]
          path

      noMeta = minimatch.filter '!*-meta.xml', matchBase: on

      diff_changed = (callback) ->
        grunt.log.writeln 'Getting changes diff...'
        git._run diff_tree('ACM', conf.git.ref, conf.git.branch), (err, res) ->
          return handleError err, callback if err
          doc = new DOMParser().parseFromString pkg_tmpl
          
          unless _.trim res
            grunt.file.write 'pkg/src/package.xml', pd.xml doc.toString()
            return callback()
            
          archive_cmd = "archive -0 -o pkg.zip #{conf.git.branch}".split ' '

          files = _.words(res.replace(/,/g, ''), /.+/g)
            .filter(minimatch.filter '!{.*,package.xml}', matchBase: on)
          unless grunt.config 'sfdc.options.fullDeploy'
            files.forEach (path) -> archive_cmd.push path
          files = files.map (path) -> path.replace /^src\//, ''
          
          git._run archive_cmd, (err, res) ->
            return handleError err, callback if err
            grunt.log.writeln 'Extracting diff archive...'
            new AdmZip('repo/pkg.zip').extractAllTo 'pkg'
            
            grunt.log.writeln 'Building package xml...'

            async.each _.keys(describeByDir), (dir, cb) ->
              describe = describeByDir[dir]
              return cb() unless describe.inFolder
              glob "#{dir}/*-meta.xml", cwd: 'pkg/src', (err, res) ->
                if not err and files.length
                  res.forEach (path) ->
                    suffix = if (suffix = describe.suffix)? then ".#{suffix}" else ''
                    files.push path[...path.lastIndexOf '-meta.xml'] + suffix
                cb()
            , ->
              componentMap = _(files).filter(noMeta).sort().groupBy(groupByType).transform(trimNames).value()
              root = _.first doc.getElementsByTagName 'Package'

              _.keys(componentMap).sort().forEach (type) ->
                list = componentMap[type]
                _types = doc.createElement 'types'
                _name = doc.createElement 'name'
                _name.appendChild doc.createTextNode type
                _types.appendChild _name
                list.forEach (name) ->
                  _members = doc.createElement 'members'
                  _members.appendChild doc.createTextNode name
                  _types.appendChild _members
                root.appendChild _types

              grunt.file.write 'pkg/src/package.xml', pd.xml doc.toString()
              callback()
      
      diff_deletes = (callback) ->
        grunt.log.writeln 'Getting deletions diff...'
        git._run diff_tree('D', conf.git.ref, conf.git.branch), (err, res) ->
          return handleError err, callback if err
          if _.trim res
            files = _.words res, /.+/g
            doc = new DOMParser().parseFromString pkg_tmpl
            grunt.log.writeln 'Building destructiveChanges xml...'
            grunt.file.write 'pkg/src/destructiveChanges.xml', pd.xml doc.toString()
          callback()

      # run diffs in parallel
      async.parallel [diff_changed, diff_deletes], ->
        grunt.log.ok 'OK'
        done()
        
  class SfdcTask
    registerTask 'sfdc', @

    login: ->
      @requires ['git:repo']
      @requiresConfig 'sfdc.options.username', 'sfdc.options.password', 'sfdc.options.securitytoken'
      done = @async()
      
      username = if conf.sfdc.sandbox
        "#{conf.sfdc.username}.#{conf.sfdc.sandbox}"
      else 
        conf.sfdc.username

      sfdc = new jsforce.Connection
        loginUrl: "https://#{if conf.sfdc.sandbox then 'test' else 'login'}.salesforce.com" 
        version: conf.sfdc.version

      grunt.log.write 'Logging in...'
      sfdc.login(username, "#{conf.sfdc.password}#{conf.sfdc.securitytoken}").then (res) ->
        grunt.log.ok()
        done()
      , (err) -> handleError err, done

    globalDescribe: ->
      @requires ['sfdc:login']
      done = @async()

      grunt.log.write 'Fetching global describe...'
      sfdc.metadata.describe().then (res) ->
        conf.sfdc.describeByName = _.indexBy res.metadataObjects, 'xmlName'
        conf.sfdc.describeByDir = _.indexBy res.metadataObjects, 'directoryName'
        grunt.log.ok()
        done()
      , (err) -> handleError err, done

  @registerTask 'default', ['validate']
  @registerTask 'validate', [
    'git:repo'
    'sfdc:login'
    'sfdc:globalDescribe'
    'clean:pkg'
    'git:pkg'
  ]
