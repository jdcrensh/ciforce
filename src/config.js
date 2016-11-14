import { env } from 'gulp-util';
import fs from 'fs-extra';
import sfdcConfig from '../sfdc.config.json';
import metadataConfig from '../metadata.config.json';
import _ from 'lodash';

_.defaults(env, {
  'metadata-excludes': '',
  'metadata-includes': '',
  'git-dir': 'repo',
  'git-dryrun': false,
  'git-tagref': false,
  'sf-sandbox': sfdcConfig.sandbox,
  'sf-username': sfdcConfig.username,
  'sf-password': sfdcConfig.password,
  'sf-securitytoken': sfdcConfig.securitytoken,
});

// git configuration
const git = {
  config: {
    push: {
      default: 'simple',
    },
    user: {
      name: env['git-name'],
      email: env['git-email'],
    },
  },
  dir: env['git-dir'],
  ref: env['git-ref'],
  url: env['git-url'],
  branch: env['git-branch'],
  commitmsg: env['git-commitmsg'],
  dryrun: env['git-dryrun'],
  tagref: env['git-tagref'],
};

// salesforce configuration
const sfdc = {
  sandbox: env['sf-sandbox'],
  username: env['sf-username'],
  password: env['sf-password'],
  securitytoken: env['sf-securitytoken'],
  deployRequestId: env['sf-deployrequestid'],
  version: sfdcConfig.version,
  checkOnly: sfdcConfig.checkOnly,
  allowMissingFiles: sfdcConfig.allowMissingFiles,
  ignoreWarnings: sfdcConfig.ignoreWarnings,
  maxPoll: sfdcConfig.maxPoll,
  pollWaitMillis: sfdcConfig.pollWaitMillis,
  testReportsDir: sfdcConfig.testReportsDir,
  fullDeploy: sfdcConfig.fullDeploy,
  undeployMissing: sfdcConfig.undeployMissing,
  metadata: {
    include: {
      types: env['metadata-includes'].split(','),
    },
    exclude: {
      types: env['metadata-excludes'].split(','),
    },
  },
};

// init metadata includes
if (sfdc.metadata.include.types == null) {
  sfdc.metadata.include.types = fs.readFileSync('metadata-types.txt').toString().split(/\r?\n/);
}

// init metadata excludes
sfdc.metadata.exclude.components = _.extend(
  metadataConfig.defaultExcludes,
  sfdc.metadata.include.types.reduce((acc, type) => {
    acc[type] = (env[`${type}-excludes`] || '').split(',');
    return acc;
  }, {})
);

// export config
export { git, sfdc };
