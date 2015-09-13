fs = require 'fs'
os = require 'os'
jsforce = require 'jsforce'
xmldom = require 'xmldom'
_ = require 'lodash'

module.exports = (grunt) ->
  sfdc = null

  # load grunt tasks
  require('load-grunt-tasks')(@)

  # init configuration
  @initConfig 
    pkg: @file.readJSON 'package.json'
    clean: ['./build']
    git:
      config:
        push: default: 'simple'
        user:
          name: @option 'git-name'
          email: @option 'git-email'
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

  badTarget = ->
    grunt.fatal if target?
      "#{@name}: invalid target (#{@target})"
    else
      "#{@name}: no target specified"

  handleError = (err, done) ->
    grunt.log.error()
    grunt.fatal err
    done false

  tasks = 
    validate:
      default: =>
        @task.run 'git:initRepo'
        @task.run 'sfdc:login'
        @task.run 'sfdc:globalDescribe'

    git:
      default: (target) -> do _.bind (tasks[@name][target] ? badTarget), @
      
      initRepo: ->
        @requiresConfig 'git.config.user.name', 'git.config.user.email', 'git.repoUrl', 'git.repoBranch'
        grunt.log.write 'initializing repo...'
        grunt.log.ok()

    sfdc:
      default: (target) -> do _.bind (tasks[@name][target] ? badTarget), @
      
      login: ->
        @requires ['git:initRepo']
        @requiresConfig 'sfdc.options.username', 'sfdc.options.password', 'sfdc.options.securitytoken'
        opts = @options()
        username = opts.username + (if opts.instance then ".#{opts.instance}" else '')
        password = "#{opts.password}#{opts.securitytoken}"
        
        sfdc = new jsforce.Connection
          loginUrl: "https://#{if opts.instance then 'test' else 'login'}.salesforce.com" 
          version: opts.version

        done = @async()
        grunt.log.write 'logging in...'
        sfdc.login(username, password).then (res) ->
          grunt.log.ok()
          done()
        , (err) -> handleError err, done

      globalDescribe: ->
        @requires ['sfdc:login']
        done = @async()
        grunt.log.write 'fetching global describe...'
        sfdc.metadata.describe().then (res) ->
          grunt.config 'sfdc.describe', _.indexBy res.metadataObjects, 'xmlName'
          grunt.log.ok()
          done()
        , (err) -> handleError err, done

  @file.mkdir 'build'

  @registerTask 'default', ['validate']
  @registerTask 'validate', tasks.validate.default
  @registerTask 'sfdc', tasks.sfdc.default
  @registerTask 'git', tasks.git.default
