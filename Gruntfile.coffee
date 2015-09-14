module.exports = (grunt) ->
  jsforce = require 'jsforce'
  DOMParser = require('xmldom').DOMParser
  xpath = require 'xpath'
  pd = require('pretty-data').pd
  _ = require 'lodash'

  sfdc = pkgxml = null
  tasks = {}

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
  for type in @config 'sfdc.options.metadata.include.types'
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
    grunt.registerTask name, -> _.bind(runTask, @)(tasks[@name] ?= new clazz())

  class GitTask
    registerTask 'git', @

    repo: ->
      @requiresConfig 'git.options.config.user.name',
        'git.options.config.user.email', 'git.options.repoUrl', 'git.options.repoBranch'

      outputHandler = (command, stdout, stderr) ->
        stdout.on 'data', (buf) -> grunt.log.writeln _.trim buf
        stderr.on 'data', (buf) -> grunt.log.writeln _.trim buf

      grunt.file.mkdir 'repo'
      git = require('simple-git') 'repo'
      opts = @options()
      done = @async()

      git._run 'config remote.origin.url', (err, url) ->
        return handleError err, done if err
        git.outputHandler outputHandler
        if _.trim(url) is opts.repoUrl
          # fetch
          grunt.log.subhead 'git fetch'
          git.fetch (err, res) ->
            return handleError err, done if err
            grunt.log.ok 'OK'
            # checkout
            grunt.log.subhead 'git checkout'
            git.checkoutLocalBranch opts.repoBranch, ->
              grunt.log.ok 'OK'
              # reset
              grunt.log.subhead 'git reset'
              git._run "reset --hard origin/#{opts.repoBranch}", (err, res) ->
                return handleError err, done if err
                # clean
                grunt.log.subhead 'git clean'
                git._run 'clean -fd', (err, res) ->
                  return handleError err, done if err
                  grunt.log.ok 'OK'
                  done()
        else
          grunt.file.delete 'repo'
          git._baseDir = null
          # clone
          grunt.log.subhead 'git clone'
          git._run "clone --branch=#{opts.repoBranch} #{opts.repoUrl} repo", (err, res) ->
            return handleError err, done if err
            git._baseDir = 'repo'
            done()

    pkg: ->
      git = require('simple-git') 'repo'
      done = @async()
      opts = @options()
      
      diff_tree = (filter, ref1, ref2) ->
        "diff-tree -r --no-commit-id --name-only --minimal --diff-filter=#{filter} #{ref1} #{ref2}"
      
      branch = grunt.config 'git.options.repoBranch'

      grunt.log.write "Getting changes diff..."
      git._run diff_tree('ACM', opts.instance, branch), (err, res) ->
        return handleError err, done if err
        grunt.log.ok()
        archive_cmd = "archive -o pkg.zip #{branch}".split ' '
        archive_cmd.push file for file in _.words res, /.+/g
        git._run archive_cmd, (err, res) ->
          return handleError err, done if err
          grunt.file.delete 'pkg' if grunt.file.exists 'pkg'
          grunt.log.write 'Extracting diff archive...'
          AdmZip = require 'adm-zip'
          new AdmZip('repo/pkg.zip').extractAllTo 'pkg'
          grunt.log.ok()

          grunt.log.write 'Getting deletions diff...'
          git._run diff_tree('D', opts.instance, branch), (err, res) ->
            return handleError err, done if err
            grunt.log.ok()
            console.log res
            grunt.event.emit 'onAfterGitPkg'
            done()
      
  class SfdcTask
    registerTask 'sfdc', @

    login: ->
      @requires ['git:repo']
      @requiresConfig 'sfdc.options.username', 'sfdc.options.password', 'sfdc.options.securitytoken'
      done = @async()
      opts = @options()

      username = opts.username + (if opts.instance then ".#{opts.instance}" else '')
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
        grunt.config 'sfdc.describeByName', _.indexBy res.metadataObjects, 'xmlName'
        grunt.config 'sfdc.describeByDir', _.indexBy res.metadataObjects, 'directoryName'
        grunt.log.ok()
        done()
      , (err) -> handleError err, done

    packageXml: ->
      @requires ['git:repo', 'sfdc:globalDescribe']
      opts = @options()
      grunt.log.write 'Initializing package xml...'
      namespace = 'http://soap.sforce.com/2006/04/metadata'
      doc = new DOMParser().parseFromString "<Package xmlns=\"#{namespace}\"><version>#{opts.version}</version></Package>"
      grunt.log.ok()
      grunt.task.run 'git:pkg'

      grunt.event.once 'onAfterGitPkg', ->
        grunt.file.write 'pkg/src/package.xml', pd.xml doc.toString()
        grunt.file.write 'pkg/src/destructiveChanges.xml', pd.xml doc.toString()

      # root = doc.getElementsByTagName('Package')[0]
      # for type in opts.metadata.include.types
      #   types = doc.createElement 'types'
      #   name = doc.createElement 'name'
      #   name.appendChild doc.createTextNode type
      #   types.appendChild name
      #   root.appendChild types
      # grunt.file.write 'build/package.xml', pd.xml doc.toString()

  @registerTask 'default', ['validate']
  @registerTask 'validate', [
    'git:repo'
    'sfdc:login'
    'sfdc:globalDescribe'
    'sfdc:packageXml'
  ]
