_ = require('lodash')
jsforce = require('jsforce')
DOMParser = require('xmldom').DOMParser
xpath = require('xpath')
pd = require('pretty-data').pd

getClassName = (obj) ->
  res = obj.constructor.toString().match /function (.{1,})\(/
  if res?.length > 1 then res[1] else ''

module.exports = (grunt) ->
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

  # runs a task target method (bound to grunt task) given its class
  # instance; function assumes that we are bound to the grunt task
  runTask = (instance) ->
    fn = if (target = @args[0])? then instance[target] else instance.default
    do _.bind (fn ? badTarget), @
    
  badTarget = ->
    grunt.warn if (target = @args[0])?
      "#{@name}: target not defined for this task (#{target})"
    else
      "#{@name}: default target not defined for this task"

  # convenience mixin for registering a task. binds runTask to the grunt task
  registerTask = (name, clazz) ->
    grunt.registerTask name, -> _.bind(runTask, @)(tasks[@name] ?= new clazz())

  class ValidateTask
    registerTask 'validate', @

    default: ->
      grunt.task.run 'git:initRepo'
      grunt.task.run 'sfdc:login'
      grunt.task.run 'sfdc:globalDescribe'
      grunt.task.run 'sfdc:packageXml'

  class GitTask
    registerTask 'git', @

    initRepo: ->
      @requiresConfig 'git.options.config.user.name',
        'git.options.config.user.email', 'git.options.repoUrl', 'git.options.repoBranch'
      opts = @options()

      grunt.file.mkdir 'repo'
      git = require('simple-git') 'repo'

      outputHandler = (command, stdout, stderr) ->
        stdout.on 'data', (buf) -> grunt.log.writeln _.trim buf
        stderr.on 'data', (buf) -> grunt.log.writeln _.trim buf
          
      done = @async()
      git._run 'config remote.origin.url', (err, url) ->
        return handleError err, done if err
        git.outputHandler outputHandler
        if _.trim(url) is opts.repoUrl
          grunt.log.subhead 'git fetch'
          git.fetch (err, res) ->
            return handleError err, done if err
            grunt.log.subhead 'git reset'
            git._run "reset --hard origin/#{opts.repoBranch}", (err, res) ->
              return handleError err, done if err
              grunt.log.subhead 'git clean'
              git._run 'clean -fd', (err, res) ->
                return handleError err, done if err
                grunt.log.writeln()
                grunt.log.ok 'OK'
                done()
        else
          grunt.file.delete 'repo'
          git._baseDir = null
          grunt.log.subhead 'git clone'
          git.clone opts.repoUrl, 'repo', (err, data) ->
            return handleError err, done if err
            git._baseDir = 'repo'
            git.checkoutLocalBranch opts.repoBranch, ->
              grunt.log.writeln()
              grunt.log.ok 'OK'
              done()

  class SfdcTask
    registerTask 'sfdc', @

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
      grunt.log.write 'Logging in...'
      sfdc.login(username, password).then (res) ->
        grunt.log.ok()
        done()
      , (err) -> handleError err, done

    globalDescribe: ->
      @requires ['sfdc:login']
      done = @async()
      grunt.log.write 'Fetching global describe...'
      sfdc.metadata.describe().then (res) ->
        grunt.config 'sfdc.describe', _.indexBy res.metadataObjects, 'xmlName'
        grunt.log.ok()
        done()
      , (err) -> handleError err, done

    packageXml: ->
      opts = @options()
      grunt.verbose.write 'Initializing package xml...'
      namespace = 'http://soap.sforce.com/2006/04/metadata'
      doc = new DOMParser().parseFromString "<Package xmlns=\"#{namespace}\"><version>#{opts.version}</version></Package>"
      grunt.verbose.ok()

      root = doc.getElementsByTagName('Package')[0]
      for type in opts.metadata.include.types
        types = doc.createElement 'types'
        name = doc.createElement 'name'
        name.appendChild doc.createTextNode type
        types.appendChild name
        root.appendChild types
      grunt.file.write 'build/package.xml', pd.xml doc.toString()

  @registerTask 'default', ['validate']
