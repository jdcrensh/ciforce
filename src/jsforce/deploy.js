import archiver from 'archiver';
import DeployResult from './deployResult';
import path from 'path';

let conn;

const connection = (_conn) => {
  if (_conn) {
    conn = _conn;
  }
  return conn;
};

const deployFromZipStream = function (zipStream, options) {
  conn = connection();
  console.log('Deploying to server...');
  conn.metadata.pollTimeout = options.pollTimeout || (60 * 1000);
  conn.metadata.pollInterval = options.pollInterval || (5 * 1000);
  return conn.metadata.deploy(zipStream, options);
};

const deployFromFileMapping = function (mapping, options) {
  const archive = archiver('zip');
  archive.bulk(mapping);
  archive.finalize();
  return deployFromZipStream(archive, options);
};

const deployFromDirectory = (packageDirectoryPath, options) => {
  const base = path.basename(packageDirectoryPath);
  return deployFromFileMapping({
    expand: true,
    cwd: path.join(packageDirectoryPath, '..'),
    src: [`${base}/**`],
  }, options);
};

const reportDeployResult = (res) => {
  return new DeployResult(res).report();
};

export {
  connection,
  DeployResult,
  deployFromZipStream,
  deployFromFileMapping,
  deployFromDirectory,
  reportDeployResult,
};
