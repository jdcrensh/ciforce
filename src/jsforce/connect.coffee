jsforce = require 'jsforce'
Promise = jsforce.Promise

CONNECTION_CONFIG_PROPS = [
  'loginUrl'
  'accessToken'
  'instanceUrl'
  'refreshToken'
  'clientId'
  'clientSecret'
  'redirectUri'
  'logLevel'
  'version'
]

connect = (options) ->
  conn = undefined
  Promise.resolve().then ->
    if options.connection
      conn = jsforce.registry.getConnection options.connection
      if !conn
        throw new Error "No connection named '#{options.connection}' in registry"
    else if options.username and options.password
      config = {}
      CONNECTION_CONFIG_PROPS.forEach (prop) ->
        if options[prop]
          config[prop] = options[prop]
      conn = new jsforce.Connection config
      conn.login options.username, options.password
    else
      throw new Error 'Credential to salesforce server is not found in options.\n' +
                      'Specify "username" and "password" in options.'
  .then ->
    if options.logger
      logger = options.logger
      conn.identity().then (identity) ->
        logger.log "Logged in as: #{identity.username}"
        conn
    conn

module.exports = connect
