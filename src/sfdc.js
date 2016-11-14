import async from 'async';
import gutil from 'gulp-util';
// import del from 'del';
import fs from 'fs-extra';
import path from 'path';
import _ from 'lodash';
import console from 'better-console';
import xpath from 'xpath';
import xmlpoke from 'xmlpoke';
import { DOMParser } from 'xmldom';
// import mm from 'mavensmate';

let deployResult;
let lastDeployResult;
let canceled;

const { config, db, jsforce } = require('require-dir')('.', { recurse: true });

let conn = deployResult = lastDeployResult = canceled = null;

const SF_NAMESPACE = 'http://soap.sforce.com/2006/04/metadata';

const SF_OPTS = {
  username: config.sfdc.sandbox ?
    `${config.sfdc.username}.${config.sfdc.sandbox}`
  :
    config.sfdc.username,
  password: `${config.sfdc.password}${config.sfdc.securitytoken}`,
  loginUrl: `https://${['login', 'test'][+config.sfdc.sandbox]}.salesforce.com`,
  version: config.sfdc.version,
  logger: gutil,
};

const excludes = {};

const handleError = function (err, done) {
  gutil.log(gutil.colors.red(err));
  return done(err, false);
};

const updateDeployResult = function (res) {
  [lastDeployResult, deployResult] = [deployResult, new jsforce.deploy.DeployResult(res)];
  return deployResult;
};

const getDeployResult = () => deployResult || {};
// const getRunTestResult = () => (deployResult || {}).runTestResult || {};
// const getComponentResults = () => (deployResult || {}).componentResults || {};

const typeQueries = () =>
  db.metadata.find().map(obj => ({ type: obj.xmlFolderName != null ? obj.xmlFolderName : obj.xmlName }))
;

const folderQueries = function () {
  const folderTypes = _.indexBy(db.metadata.find({ inFolder: true }), 'xmlFolderName');
  return db.components.find({ type: { $in: Object.keys(folderTypes),
  } }).map(obj =>
    ({
      type: folderTypes[obj.type].xmlName,
      folder: obj.fullName,
    })
  );
};

const listQuery = (query, next) =>
  conn.metadata.list(query, (err, res) => {
    if (res != null) { db.components.insert(res); }
    return next(err);
  })
;

// exitHandler = (options={}, err) -> ->
//   if not canceled and options.cancel and (res = getDeployResult())?.id
//     canceled = true
//     conn.metadata._invoke 'cancelDeploy', id: res.id
//   else if canceled
//     process.exit()
//
// process.on 'exit', exitHandler()
// process.on 'SIGINT', exitHandler cancel: true
// process.on 'uncaughtException', exitHandler()

const deployComplete = function (err, res, done) {
  if (err) { return handleError(err, done); }
  res = getDeployResult();
  res.report();
  done(res.success);
  if (canceled) { return process.exit(); }
};

const mapObjectComponentNames = (arr, filterFn) =>
  _.chain(arr)
    .compactArray()
    .mapProperty('fullName')
    .compact()
    .filter(filterFn)
    .value()
;

export default {
  login(done) {
    return jsforce.connect(SF_OPTS)
      .then(_conn => jsforce.deploy.connection(conn = _conn))
      .catch(done);
  },

  describeMetadata(done) {
    return conn.metadata.describe()
      .then(res => db.metadata.insert(res.metadataObjects))
      .catch(done);
  },

  describeGlobal(done) {
    return conn.describeGlobal()
      .then(res => db.global.insert(res.sobjects))
      .catch(done);
  },

  listMetadata(done) {
    // retrieve metadata listings in chunks, then folder contents
    return async.eachSeries([typeQueries, folderQueries], (fn, next) => {
      async.each(_.chunk(fn, 3), listQuery, next);
    }, done);
  },

  excludeManaged(done) {
    async.waterfall([
      (done) => {
        return fs.readFile('pkg/src/package.xml', 'utf-8', (err, xml) => {
          let names;
          if (!err) {
            const doc = new DOMParser().parseFromString(xml);
            const select = xpath.useNamespaces({ sf: SF_NAMESPACE });
            const nodes = select("//sf:name[text()='CustomObject']/../sf:members/text()", doc);
            names = _.mapProperty(nodes, 'nodeValue');
          }
          return done(err, names);
        });
      },
      (names, done) => {
        async.each(_.chunk(names, 10), (names, done) => {
          conn.metadata.read('CustomObject', names).then((metadata) => {
            metadata = _.compactArray(metadata);
            return async.each(metadata, (meta, done) => {
              if (meta.fullName) {
                excludes[meta.fullName] = {};
                const mapping = excludes[meta.fullName];
                mapping.fields = mapObjectComponentNames(meta.fields, name => name.match(/__.+__c$/g));
                mapping.webLinks = mapObjectComponentNames(meta.webLinks, name => name.includes('__'));
              }
              // mapping.listViewButtons = mapObjectComponentNames meta.searchLayouts
              async.setImmediate(done);
            }, done);
          })
          .catch(done);
        }, done);
      },
    ], (err) => {
      excludes.CustomObject = _.pick(excludes.CustomObject, types => _.some(types, _.size));
      return done(err);
    });
  },

  removeExcludes(done) {
    return async.forEachOf(excludes.CustomObject, (types, name, done) =>
      xmlpoke(`pkg/src/objects/${name}.object`, (xml) => {
        xml = xml.addNamespace('sf', xml.SF_NAMESPACE);
        ['fields', 'webLinks'].forEach(type =>
          types[type].forEach(name => xml.remove(`//sf:${type}/sf:fullName[text()='${name}']/..`))
        );
        return done();
      })

    , done);
  },

  validate(done) {
    // process.stdin.resume()

    return async.during((done) => {
      const res = getDeployResult();
      if (res.id) {
        return conn.metadata.checkDeployStatus(res.id, true)
          .then((res) => {
            res = updateDeployResult(res);
            // res.reportFailures res.getRecentFailures lastDeployResult
            if (lastDeployResult.lastModifiedDate !== res.lastModifiedDate) {
              console.log(res);
            }
            const msg = res.statusMessage();
            if (msg) { // and lastDeployResult.statusMessage() isnt msg
              if (res.done) {
                gutil.log(gutil.colors[res.success ? 'green' : 'red'](msg));
              } else {
                gutil.log(msg);
              }
            }
            return done(null, !res.done);
          })
          .catch(done);
      }
      return jsforce.deploy.deployFromDirectory(path.join(config.git.dir, 'src'), {
        checkOnly: true,
        purgeOnDelete: true,
        rollbackOnError: true,
        runAllTests: false,
        testLevel: 'RunLocalTests',
      })
      .check((err, res) => {
        if (!err) {
          gutil.log(updateDeployResult(res).statusMessage());
        }
        return done(err, true);
      });
    }, next => setTimeout(next, 1000), err => deployComplete(err, done));
  },

  retrieve(done) {
    return conn.metadata.retrieve({ packageNames: 'unpackaged' }).then((res) => {
      gutil.log(res);
      res.pipe(fs.createWriteStream('pkg.zip'));
      return done();
    })
    .catch((err) => { throw err; });
  },

  project(done) {
    return done();
    // del('proj');
    // const client = mm.createClient({
    //   name: 'mm-client',
    //   isNodeApp: true,
    //   verbose: true,
    // });
    // return client.executeCommand('new-project', {
    //   name: 'myproject',
    //   workspace: 'proj',
    //   username: config.sfdc.username,
    //   password: config.sfdc.password + config.sfdc.securitytoken,
    //   package: {},
    // });
  },
};
