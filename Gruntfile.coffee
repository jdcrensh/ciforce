module.exports = (grunt) ->
  fs = require 'fs-extra'
  glob = require 'glob'
  async = require 'async'
  jsforce = require 'jsforce'
  DOMParser = require('xmldom').DOMParser
  xpath = require 'xpath'
  pd = require('pretty-data').pd
  _ = require 'lodash'

  sfdc = null
  instances = {}

  # load grunt tasks
  require('load-grunt-tasks') @

  # init configuration
  @initConfig 
    pkg: @file.readJSON 'package.json'
    clean: ['build', 'repo']
    git:
      options:
        config:
          push: default: 'simple'
          user:
            name: @option 'git-name'
            email: @option 'git-email'
        instance: @option('sf-instance') or 'prod'
        repoUrl: @option 'repourl'
        repoBranch: @option 'branch'
        commitMessage: @option 'commit-msg'
        dryrun: @option('git-dryrun') ? false
        tagref: @option('git-tagref') ? true
    sfdc:
      options:
        instance: @option('sf-instance') or ''
        username: @option 'sf-username'
        password: @option 'sf-password'
        securitytoken: @option 'sf-securitytoken'
        deployRequestId: @option 'sf-deployrequestid'
        version: '<%= pkg.sfdc.version %>'
        checkOnly: '<%= pkg.sfdc.checkOnly %>'
        allowMissingFiles: '<%= pkg.sfdc.allowMissingFiles %>'
        ignoreWarnings: '<%= pkg.sfdc.ignoreWarnings %>'
        maxPoll: '<%= pkg.sfdc.maxPoll %>'
        pollWaitMillis: '<%= pkg.sfdc.pollWaitMillis %>'
        testReportsDir: '<%= pkg.sfdc.testReportsDir %>'
        fullDeploy: '<%= pkg.sfdc.fullDeploy %>'
        undeployMissing: '<%= pkg.sfdc.undeployMissing %>'
        metadata:
          include: types: @option('metadata-includes')?.split(',') ? @file.read('metadata-types.txt').split /\r?\n/
          exclude: types: (@option('metadata-excludes') ? '').split ','
  
  # init metadata component excludes
  excludes = @config('pkg').defaultExcludes
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
        'git.options.config.user.email', 'git.options.repoUrl', 'git.options.repoBranch'

      outputHandler = (command, stdout, stderr) ->
        stdout.on 'data', (buf) -> grunt.log.writeln _.trim buf
        stderr.on 'data', (buf) -> grunt.log.writeln _.trim buf

      fs.ensureDir 'repo'
      git = require('simple-git') 'repo'
      opts = @options()
      done = @async()

      git._run 'config remote.origin.url', (err, url) ->
        return handleError err, done if err
        git.outputHandler outputHandler

        tasks = []
        if _.trim(url) is opts.repoUrl 
          # fetch
          tasks.push (callback) ->
            grunt.log.subhead 'git fetch'
            git._run 'fetch --all --tags', (err, res) ->
              return handleError err, callback if err
              grunt.log.ok 'OK'
              callback()
          # checkout
          tasks.push (callback) ->
            grunt.log.subhead 'git checkout'
            git.checkout opts.repoBranch, (err, res) ->
              return handleError err, callback if err
              grunt.log.ok 'OK'
              callback()
          # reset
          tasks.push (callback) ->
            grunt.log.subhead 'git reset'
            git._run "reset --hard origin/#{opts.repoBranch}", (err, res) ->
              return handleError err, callback if err
              grunt.log.ok 'OK'
              callback()
          # clean
          tasks.push (callback) ->
            grunt.log.subhead 'git clean'
            git._run 'clean -fd', (err, res) ->
              return handleError err, callback if err
              grunt.log.ok 'OK'
              callback()
        else
          # clone
          tasks.push (callback) ->
            grunt.file.delete 'repo'
            git._baseDir = null
            grunt.log.subhead 'git clone'
            git._run "clone --branch=#{opts.repoBranch} #{opts.repoUrl} repo", (err, res) ->
              return handleError err, callback if err
              git._baseDir = 'repo'
              grunt.log.ok 'OK'
              callback()

        async.series tasks, -> done()

    pkg: ->
      git = require('simple-git') 'repo'
      done = @async()
      opts = @options()
      branch = opts.repoBranch
      version = grunt.config 'sfdc.options.version'
      namespace = 'http://soap.sforce.com/2006/04/metadata'
      pkg_tmpl = "<Package xmlns=\"#{namespace}\"><version>#{version}</version></Package>"
      
      diff_tree = (filter, ref1, ref2) ->
        "diff-tree -r --no-commit-id --name-only --minimal --diff-filter=#{filter} #{ref1} #{ref2}"
      
      diff_tasks = []

      # diff changes
      diff_tasks.push (callback) ->
        grunt.log.writeln 'Getting changes diff...'
        git._run diff_tree('ACM', opts.instance, branch), (err, res) ->
          return handleError err, callback if err
          res = res.replace /,/g, '' # simple-git somehow scatters commas into the result
          archive_cmd = "archive -o pkg.zip #{branch}".split ' '
          unless grunt.config 'sfdc.options.fullDeploy'
            _.words(res, /.+/g).forEach (path) -> archive_cmd.push path
          git._run archive_cmd, (err, res) ->
            return handleError err, callback if err
            fs.removeSync 'pkg'
            grunt.log.writeln 'Extracting diff archive...'
            AdmZip = require 'adm-zip'
            new AdmZip('repo/pkg.zip').extractAllTo 'pkg'
            
            grunt.log.writeln 'Building package xml...'
            doc = new DOMParser().parseFromString pkg_tmpl
            tree = glob.sync '**', cwd: 'pkg/src', nosort: on, nodir: on, ignore: ['**/*-meta.xml', 'package.xml']

            describeByDir = grunt.config 'sfdc.describe.byDir'
            describeByName = grunt.config 'sfdc.describe.byName'

            _.forEach describeByDir, (describe, dir) ->
              return unless describe.inFolder
              glob.sync("#{dir}/*-meta.xml", cwd: 'pkg/src').forEach (path) ->
                suffix = if (suffix = describe.suffix)? then ".#{suffix}" else ''
                tree.push path[...path.lastIndexOf '-meta.xml'] + suffix

            groupByType = (path) ->
              describeByDir[path[0...path.indexOf '/']].xmlName

            trimNames = (result, list, name) ->
              describe = describeByName[name]
              result[name] = list.map (path) ->
                path = path.substring 1 + path.indexOf '/'
                if (suffix = describe.suffix)?
                  path = path[0...path.lastIndexOf(suffix) - 1]
                path

            componentMap = _(tree).sort().groupBy(groupByType).transform(trimNames).value()

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

      # diff deletions
      diff_tasks.push (callback) ->
        grunt.log.writeln 'Getting deletions diff...'
        git._run diff_tree('D', opts.instance, branch), (err, res) ->
          return handleError err, callback if err
          if _.trim res
            files = _.words res, /.+/g
            grunt.log.writeln 'Building destructiveChanges xml...'
            doc = new DOMParser().parseFromString pkg_tmpl
            grunt.file.write 'pkg/src/destructiveChanges.xml', pd.xml doc.toString()
          callback()

      # run async
      async.parallel diff_tasks, ->
        grunt.log.ok 'OK'
        done()
        
  class SfdcTask
    registerTask 'sfdc', @

    login: ->
      @requires ['git:repo']
      @requiresConfig 'sfdc.options.username', 'sfdc.options.password', 'sfdc.options.securitytoken'
      done = @async()
      opts = @options()

      username = opts.username + '.jondev'
      password = "#{opts.password}#{opts.securitytoken}"
      
      sfdc = new jsforce.Connection
        loginUrl: "https://#{if opts.instance then 'test' else 'login'}.salesforce.com" 
        version: opts.version

      grunt.log.write 'Logging in...'
      sfdc.login(username, password).then (res) ->
        grunt.log.ok()
        done()
      , (err) -> handleError err, done

    globalDescribe: ->
      @requires ['sfdc:login']
      done = @async()
      opts = @options()

      grunt.log.write 'Fetching global describe...'
      sfdc.metadata.describe().then (res) ->
        grunt.config 'sfdc.describe.byName', _.indexBy res.metadataObjects, 'xmlName'
        grunt.config 'sfdc.describe.byDir', _.indexBy res.metadataObjects, 'directoryName'
        grunt.log.ok()
        done()
      , (err) -> handleError err, done

  @registerTask 'default', ['validate']
  @registerTask 'validate', [
    'git:repo'
    'sfdc:login'
    'sfdc:globalDescribe'
    'git:pkg'
  ]
