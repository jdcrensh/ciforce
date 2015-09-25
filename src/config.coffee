pkg   = require '../package.json'
fs    = require 'fs-extra'
{env} = require 'gulp-util'


class ConfigModule

  git:
    config:
      push: default: 'simple'
      user: name: env['git-name'], email: env['git-email']
    ref: env['git-ref']
    url: env['git-url']
    branch: env['git-branch']
    commitmsg: env['git-commitmsg']
    dryrun: env['git-dryrun'] ? false
    tagref: env['git-tagref'] ? true

  sfdc:
    sandbox: env['sf-sandbox'] ? pkg.sfdc.sandbox
    username: env['sf-username'] ? pkg.sfdc.username
    password: env['sf-password'] ? pkg.sfdc.password
    securitytoken: env['sf-securitytoken'] ? pkg.sfdc.securitytoken
    deployRequestId: env['sf-deployrequestid']
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
      include: types: env['metadata-includes']?.split ','
      exclude: types: env['metadata-excludes']?.split(',') ? []

  constructor: ->
    # init metadata includes
    @sfdc.metadata.include.types ?= @readLines 'metadata-types.txt'

    # init metadata excludes
    excludes = pkg.defaultExcludes
    @sfdc.metadata.include.types.forEach (type) ->
      if (val = env["#{type}-excludes"])? or val is ''
        excludes[type] = val?.split ','
    @sfdc.metadata.exclude.components = excludes

  readLines: (path) ->
    fs.readFileSync(path).toString().split /\r?\n/


module.exports = new ConfigModule()
