fs = require 'fs-extra'
glob = require 'glob'
minimatch = require 'minimatch'
async = require 'async'
archiver = require 'archiver'
Zip = require 'adm-zip'
Git = require 'simple-git'
lokijs = require 'lokijs'
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

  db = new lokijs 'default'
  
  describes =
    metadata: db.addCollection('metadataDescribe', indices: ['xmlName', 'directoryName'], unique: ['xmlName', 'directoryName'])
    components: db.addCollection('componentDescribe')
    global: db.addCollection('globalDescribe')

  componentResult = db.addCollection 'componentResult'
  runTestResult = db.addCollection 'runTestResult'

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
  asyncCallback = (err, callback) ->
    callback err

  gruntAsyncCallback = (err, callback) ->
    callback !err

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
      
  unzip = (path, target) ->
    zip = new Zip 'repo/pkg.zip'
    zip.extractAllTo 'pkg'

  namespace = 'http://soap.sforce.com/2006/04/metadata'
  pkg_tmpl = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Package xmlns=\"#{namespace}\"></Package>"

  writePackage = (componentMap, path) ->
    doc = new DOMParser().parseFromString pkg_tmpl
    root = _.first doc.getElementsByTagName 'Package'
    _.keys(componentMap).sort().forEach (type) ->
      list = componentMap[type]
      _types = doc.createElement 'types'
      list.forEach (name) ->
        _members = doc.createElement 'members'
        _members.appendChild doc.createTextNode name
        _types.appendChild _members
      _name = doc.createElement 'name'
      _name.appendChild doc.createTextNode type
      _types.appendChild _name
      root.appendChild _types
    _version = doc.createElement 'version'
    _version.appendChild doc.createTextNode sfdc.version
    root.appendChild _version
    grunt.file.write path, pd.xml doc.toString()
    return

  noMeta = minimatch.filter '!*-meta.xml', matchBase: on
  metaOnly = minimatch.filter '*-meta.xml', matchBase: on

  includeMetaFiles = (files) ->
    files = _.union files, files.filter(noMeta)
      .map((path) -> path.replace /^src\//, '')
      .filter((path) -> describes.metadata.by('directoryName', path[...path.indexOf('/')]).metaFile)
      .map((path) -> "src/#{path}-meta.xml")
    files.sort()

  includeComponents = (files) ->
    files = _.union files, files.filter(metaOnly).map((path) -> path.replace '-meta.xml', '')
    files.sort()

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
          return asyncCallback err, callback if err
          grunt.log.ok 'OK'
          callback()

      git._run 'config remote.origin.url', (err, url) ->
        return gruntAsyncCallback err, done if err
        url = _.trim url

        outfn = (buf) ->
          str = _.trim(buf)['cyan']
          unless ~str.indexOf('error:') or ~str.indexOf('fatal:')
            grunt.log.writeln str

        git.outputHandler (cmd, stdout, stderr) ->
          stdout.on 'data', outfn
          stderr.on 'data', outfn

        if url is conf.git.url 
          async.series [
            git_run 'fetch --all --tags'
            git_run "checkout -f #{conf.git.branch}"
            git_run "reset --hard origin/#{conf.git.branch}"
            git_run 'clean -fd'
          ], (err) ->
            grunt.log.writeln err['red'] if err
            done !err
        else
          grunt.file.delete 'repo'
          git._baseDir = null
          git._run "clone --branch=#{conf.git.branch} #{conf.git.url} repo", (err) ->
            grunt.log.writeln err['red'] if err
            grunt.log.ok 'OK' if !err
            git._baseDir = 'repo'
            done !err

    pkg: ->
      @requires ['git:repo', 'clean:pkg']
      done = @async()

      git = new Git 'repo'

      diff_tree = (filter, ref1, ref2) ->
        "diff-tree -r --no-commit-id --name-only --minimal --diff-filter=#{filter} #{ref1} #{ref2}"

      groupByType = (path) ->
        dir = path[0...path.indexOf '/']
        describes.metadata.by('directoryName', dir).xmlName

      pathsToNames = (result, list, name) ->
        suffix = describes.metadata.by('xmlName', name).suffix
        result[name] = list.map (path) ->
          path = path[path.indexOf('/') + 1..]
          # remove file ext from path
          if suffix?
            path = path[0...path.lastIndexOf(suffix) - 1]
          path

      includeFolders = (files) -> (dir, cb) ->
        describe = describes.metadata.by('directoryName', dir)
        glob "#{dir}/*-meta.xml", cwd: 'pkg/src', (err, res) ->
          cb err if err
          res.forEach (path) ->
            suffix = if (suffix = describe.suffix)? then ".#{suffix}" else ''
            files.push path[...path.lastIndexOf '-meta.xml'] + suffix
          cb()

      buildComponentMap = (files) ->
        _(files).filter(noMeta).groupBy(groupByType).transform(pathsToNames).value()

      diff_changed = (callback) ->
        grunt.log.write 'Getting changes diff...'
        git._run diff_tree('ACM', conf.git.ref, conf.git.branch), (err, res) ->
          return asyncCallback err, callback if err
          grunt.log.ok()
          
          unless _.trim res
            writePackage {}, 'pkg/src/package.xml'
            return callback()
            
          archive_cmd = "archive -0 -o pkg.zip #{conf.git.branch}".split ' '

          files = _.words(res.replace(/,/g, ''), /.+/g)
            .filter(minimatch.filter '!{.*,package.xml}', matchBase: on)

          unless grunt.config 'sfdc.options.fullDeploy'
            # include components if meta files have changed
            files = includeComponents files
            # include *-meta.xml in archive where appropriate
            files = includeMetaFiles files
            files.forEach (path) -> archive_cmd.push path

          files = files.filter(minimatch.filter '!.*').map (path) -> path.replace /^src\//, ''

          git._run archive_cmd, (err) ->
            return asyncCallback err, callback if err
            unzip 'repo/pkg.zip', 'pkg'
            directories = describes.metadata.find(inFolder: true).map (describe) -> describe.directoryName
            async.each directories, includeFolders(files), ->
              writePackage buildComponentMap(files), 'pkg/src/package.xml'
              callback()
      
      diff_deletes = (callback) ->
        return callback() unless pkg.sfdc.undeployMissing
        grunt.log.write 'Getting deletions diff...'
        git._run diff_tree('D', conf.git.ref, conf.git.branch), (err, res) ->
          return asyncCallback err, callback if err
          grunt.log.ok()
          return callback() unless _.trim res

          files = _.words(res.replace(/,/g, ''), /.+/g)
            .filter(minimatch.filter '!{.*,package.xml}', matchBase: on)
            .map (path) -> path.replace /^src\//, ''

          directories = describes.metadata.find(inFolder: true).map (describe) -> describe.directoryName
          async.each directories, includeFolders(files), ->
            writePackage buildComponentMap(files), 'pkg/src/destructiveChangesPost.xml'
            callback()

      # run diffs in parallel
      async.series [diff_changed, diff_deletes], (err) ->
        gruntAsyncCallback err, done
        
  class SfdcTask
    registerTask 'sfdc', @

    login: ->
      @requiresConfig 'sfdc.options.username', 'sfdc.options.password', 'sfdc.options.securitytoken'
      done = @async()
      
      username = if conf.sfdc.sandbox
        "#{conf.sfdc.username}.#{conf.sfdc.sandbox}"
      else 
        conf.sfdc.username

      sfdc = new jsforce.Connection
        loginUrl: "https://#{['login', 'test'][~~!!conf.sfdc.sandbox]}.salesforce.com" 
        version: conf.sfdc.version

      grunt.log.write 'Logging in...'
      sfdc.login(username, "#{conf.sfdc.password}#{conf.sfdc.securitytoken}").then (res) ->
        grunt.log.ok()
        done()
      , (err) -> gruntAsyncCallback err, done

    describeMetadata: ->
      @requires ['sfdc:login']
      done = @async()

      grunt.log.write 'Fetching global describe...'
      sfdc.metadata.describe().then (res) ->
        describes.metadata.insert res.metadataObjects
        grunt.log.ok()
        done()
      , (err) ->
        grunt.log.error err
        done false

    describeGlobal: ->
      @requires ['sfdc:login']
      done = @async()
      grunt.log.write 'Fetching SObject describe...'
      sfdc.describeGlobal().then (res) ->
        describes.global.insert res.sobjects
        grunt.log.ok()
        done()
      , (err) ->
        grunt.log.error err
        done false

    list: ->
      @requires ['sfdc:login']
      done = @async()
      grunt.log.write 'Listing metadata properties...'
      types = describes.metadata.find()
      async.each types, (type, callback) ->
        xmlName = if type.inFolder
          if type.xmlName is 'EmailTemplate'
            'EmailFolder'
          else
            "#{type.xmlName}Folder"
        else
          type.xmlName
        sfdc.metadata.list(type: xmlName).then (res) ->
          if res?
            describes.components.insert res
            grunt.verbose.ok "#{xmlName} (#{res.length ? 1})"
            if type.inFolder
              folders = describes.components.find(type: xmlName).map (obj) -> obj.fullName
              async.each folders, (folder, callback) ->
                sfdc.metadata.list(type: type.xmlName, folder: folder).then (res) ->
                  if res?
                    describes.components.insert res
                    grunt.verbose.ok "#{type.xmlName}: #{folder} (#{res.length ? 1})"
                    callback null, true
                  else
                    callback null, true
                , (err) ->
                  callback err
              , (err) ->
                if err
                  grunt.log.error err if err
                  done false
                else
                  done()
              callback null, true
          else
            callback null, true
        , (err) ->
          callback err
      , (err) ->
        if err
          grunt.log.error err if err
          done false
        else
          done()

    validate: ->
      @requires ['sfdc:login']
      opts = 
        checkOnly: true
        purgeOnDelete: true
        rollbackOnError: true
        runAllTests: false
        testLevel: 'RunLocalTests'

      archive = archiver 'zip'
      archive.directory 'pkg', ''
      archive.finalize()

      done = @async()
      oldRes = null
      deploy = sfdc.metadata.deploy archive, opts

      test = (callback) ->
        if oldRes?.id
          sfdc.metadata.checkDeployStatus oldRes.id, true, (err, res) ->
            return callback err, false if err
            res = new DeployResult res
            res.reportFailures res.getRecentFailures oldRes
            
            msg = res.statusMessage()
            if msg and oldRes.statusMessage() isnt msg
              if res.done
                if res.success then grunt.log.ok msg
                else grunt.log.error msg
              else
                grunt.log.writeln msg
            oldRes = res
            callback null, not res.done
        else
          deploy.check (err, res) ->
            oldRes = new DeployResult res
            callback err, !err

      next = (callback) ->
        setTimeout callback, 1000
      
      complete = (err) ->
        grunt.fatal err if err
        done oldRes.success

      async.during test, next, complete

    retrieve: ->
      done = @async()
      sfdc.metadata.retrieve(packageNames: 'unpackaged').then (res) ->
        console.log res
        res.pipe fs.createWriteStream 'pkg.zip'
        done()
      , (err) ->
        grunt.log.error err
        done false


  class DeployResult
    constructor: (data) ->
      _.assign @, data
      @runTestResult = new RunTestResult @
      @componentResults = new ComponentResults @

    statusMessage: ->
      msg = ''
      method = ['Deployment', 'Validation'][~~@checkOnly]
      if @status?
        status = switch @status
          when 'InProgress' then 'In Progress'
          when 'Pending' then 'Waiting for other deployments to finish'
          else @status

        msg += status

        msg += switch status
          when 'Canceled' then " by #{@canceledByName}"
          when 'Canceling' then ''
          else
            if @stateDetail? then " -- #{@stateDetail}" else ''
      msg

    getRecentFailures: (old) ->
      components: @componentResults.getRecentFailures old.componentResults
      tests: @runTestResult.getRecentFailures old.runTestResult

    reportFailures: (failures={}) ->
      if failures.components.length
        @componentResults.reportFailures failures.components
      if failures.tests.length
        @runTestResult.reportFailures failures.tests

    report: ->
      @componentResults.report()
      @runTestResult.report()

  class RunTestResult
    constructor: (deployResult) ->
      _.assign @, deployResult.details?.runTestResult ? {}
      @failures = _.compact [@failures] unless _.isArray @failures

    getRecentFailures: (old) ->
      if old?.numFailures then @failures[old.numFailures..] else []

    reportFailures: (failures) ->
      return unless failures?.length
      err = [_.repeat('-', 80), 'Test Failures:']
      failures.forEach (failure, i) ->
        stackTrace = _(failure.stackTrace.split '\n').map (line) -> "   #{line}"
        err.push """
          #{i + 1}. #{failure.name}.#{failure.methodName}
             #{failure.message}
          #{stackTrace.join '\n'}
        """
      err.push _.repeat '-', 80
      grunt.log.writelns err.join '\n'

    report: ->

  class ComponentResults
    constructor: (deployResult) ->
      @successes = deployResult.details?.componentSuccesses ? []

    getRecentFailures: (old) -> []

    reportFailures: (failures) ->
      return unless failures?.length
      failures.forEach (f) ->

    report: ->

  @registerTask 'default', ['validate']
  @registerTask 'validate', [
    'sfdc:login'
    'sfdc:describeMetadata'
    'sfdc:describeGlobal'
    'git:repo'
    'clean:pkg'
    'git:pkg'
    'sfdc:validate'
  ]
  @registerTask 'commitChanges', [
    'sfdc:login'
    'sfdc:describeMetadata'
    'sfdc:describeGlobal'
    'sfdc:list'
    'git:repo'
  ]
