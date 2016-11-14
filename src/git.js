import _ from 'lodash';
import async from 'async';
import del from 'del';
import fs from 'fs-extra';
import git from 'gulp-git';
import gulp from 'gulp';
import gutil from 'gutil';
import minimatch from 'minimatch';
import path from 'path';
import unzip from 'gulp-unzip';
import xml from './xml';

import {
  sfdc as sfdcConfig,
  git as gitConfig,
} from './config';

import {
  components as dbComponents,
  metadata as dbMetadata,
} from './db';

// package directory
const pkg = path.resolve('pkg');
// package zip path
const pkg_zip = path.resolve('pkg.zip');
// git quiet mode
const quiet = true;

const { version } = sfdcConfig;
const { branch } = gitConfig;
const cwd = gitConfig.dir; // repo directory
const repourl = gitConfig.url;
const gitref = gitConfig.ref;

const parseLine = function (line) {
  const [diffStatus, fileName] = line;

  // locate the file object by its fileName and update diffStatus if found
  let obj = dbComponents.findObject({ fileName: fileName.replace(/-meta\.xml$/, '') });
  if (obj != null) {
    obj.diffStatus = diffStatus;

  // parsing the diff's file path to generate a new file object.
  // note: the file isn't in the org so parsing deletes here is not necessary
  } else if (diffStatus !== 'D' && !fileName.match(/-meta\.xml$/)) {
    const parsedPath = path.parse(fileName);
    const base = parsedPath.base;
    const shiftPath = path.shift(parsedPath.dir);
    const dir = shiftPath[0];
    const subpath = shiftPath[1];

    const describe = dbMetadata.findObject({ directoryName: dir });
    if (describe == null) {
      console.log(`Unable to locate describe info for directoryName: ${dir}`);
      return;
    }
    obj = { fileName, diffStatus, fullName: path.join(subpath, base) };

    if (describe.suffix) {
      obj.fullName = obj.fullName.replace(new RegExp(`\\.${describe.suffix}$`), '');
    }
    obj.type = describe.xmlName;
  }

  return obj;
};

const splitLines = str => _.words(str, /.+/g);

// parse git diff output
const parseDiff = function (res = '') {
  const diffs = _.chain(_.trim(res).replace(/,/g, ''))
    .thru(splitLines)
    .map(line => [(res = /^(\w)\t(.*)/.exec(line))[1], path.shift(res[2])[1]])
    .filter(_.modArgs(minimatch.filter('!{.*,package.xml}', { matchBase: true }), line => line[1]))
    .map(parseLine)
    .compact()
    .groupBy(obj => (obj.$loki != null ? 'updates' : 'inserts'))
    .value();

  // insert/update parsed diff output
  if ((diffs.inserts || []).length) {
    dbComponents.insert(diffs.inserts);
  }
  if ((diffs.updates || []).length) {
    dbComponents.update(_.uniq(diffs.updates, obj => obj.$loki));
  }

  // diff completed
  const changes = dbComponents.find({ diffStatus: { $in: 'ACMRT'.split('') } }) || [];
  const deletes = dbComponents.find({ diffStatus: 'D' }) || [];

  gutil.log(`${changes.length} to add/update, ${deletes.length} to delete`);
  return { changes, deletes };
};

const forEachRemoteBranch = (iteratee, done) =>
  git.exec({ cwd, args: 'branch -a', quiet }, (err, res) => {
    if (err) { return done(err, res); }
    const branches = res.split('\n')
      .filter(line => line.match(/remotes\//) && !line.match(/->/))
      .map(line => _.trim(line).replace(/^remotes\/[^/]+\//, ''));
    return async.each(branches, iteratee, done);
  })
;

const pkg_diff = function (done) {
  // execute the git-diff-tree command
  const args = `diff-tree -r --no-commit-id --name-status ${gitref} ${branch}`;
  return git.exec({ args, cwd, quiet }, (err, res) => done(err, parseDiff(res)));
};

// Adds in *-meta.xml files for changes if applicable
const expandChangeset = function (changes) {
  const metaTypes = _.pluck(dbMetadata.find({ metaFile: true }), 'xmlName');
  return changes.reduce((arr, obj) => {
    arr.push(path.join('src', obj.fileName));
    if (metaTypes.includes(obj.type)) { arr.push(path.join('src', `${obj.fileName}-meta.xml`)); }
    return arr;
  }
  , []);
};

const pkg_archive = function (done, res) {
  if (res.diff.changes.length) {
    const changeset = expandChangeset(res.diff.changes);
    const args = `archive -0 -o ${pkg_zip} ${branch} '${changeset.join('\' \'')}'`;
    return git.exec({ args, cwd, quiet }, err => done(err, changeset));
  }
  return async.setImmediate(done);
};

const pkg_unarchive = function (done) {
  unzip = gulp.src(pkg_zip)
    .pipe(unzip(pkg))
    .pipe(gulp.dest(pkg));
  const complete = function () { del(pkg_zip); return done(); };
  unzip.on('end', complete);
  return unzip.on('error', complete);
};

const pkg_packageXml = function (done, res) {
  const dest = path.join(pkg, 'src', 'package.xml');
  const members = _(res.diff.changes).groupBy('memberType').mapPlucked('fullName').value();
  return xml.writePackage(members, version, dest, done);
};

const pkg_packageDestructiveXml = function (done, res) {
  const dest = path.join(pkg, 'src', 'destructiveChangesPost.xml');
  const members = _(res.diff.deletes).groupBy('memberType').mapPlucked('fullName').value();
  return xml.writePackage(members, version, dest, done);
};

export default {
  repo(done) {
    fs.ensureDirSync(cwd);
    return async.waterfall([
      (done) => {
        const args = 'config remote.origin.url';
        git.exec({ args, cwd, quiet }, done);
      },
      (res, done) => {
        if (repourl === _.trim(res)) {
          async.series([
            done => git.fetch('', '', { args: '--all --tags', cwd }, done),
            done =>
              forEachRemoteBranch((branch, done) => {
                if (branch === gitref) {
                  git.checkout(gitref, { args: '-f', cwd }, done);
                } else {
                  async.setImmediate(done);
                }
              }
              , done),
            done => git.checkout(branch, { args: '-f', cwd }, done),
            done => git.reset(`origin/${branch}`, { args: '--hard', cwd }, done),
            done => git.exec({ args: 'clean -fd', cwd, log: true }, done),
          ], done);
        } else {
          del(cwd);
          git.clone(repourl, { args: `--branch=${branch} ${cwd}` }, done);
        }
      },
    ], done);
  },

  pkg(done) {
    async.auto({
      diff: pkg_diff,
      archive: ['diff', pkg_archive],
      unarchive: ['archive', pkg_unarchive],
      packageXml: ['unarchive', pkg_packageXml],
      packageDestructiveXml: ['diff', pkg_packageDestructiveXml],
    }, done);
  },
};
