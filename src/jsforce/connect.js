import jsforce from 'jsforce';

const CONNECTION_CONFIG_PROPS = [
  'loginUrl',
  'accessToken',
  'instanceUrl',
  'refreshToken',
  'clientId',
  'clientSecret',
  'redirectUri',
  'logLevel',
  'version',
];

const connect = (options = {}) => {
  let conn;
  return jsforce.Promise.resolve().then(() => {
    if (options.connection) {
      conn = jsforce.registry.getConnection(options.connection);
      if (!conn) {
        throw new Error(`No connection named '${options.connection}' in registry`);
      }
    } else if (options.username && options.password) {
      const config = {};
      CONNECTION_CONFIG_PROPS.forEach((prop) => {
        if (options[prop]) {
          config[prop] = options[prop];
        }
      });
      conn = new jsforce.Connection(config);
      return conn.login(options.username, options.password);
    }
    throw new Error(```
      Credentials to salesforce server not given.
      Specify "username" and "password" in options.
    ```);
  })
  .then(() => {
    if (options.logger) {
      const { logger } = options;
      return conn.identity().then((identity) => {
        logger.log(`Logged in as: ${identity.username}`);
        return conn;
      });
    }
    return conn;
  });
};

export default connect;
