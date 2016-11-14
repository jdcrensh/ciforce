import _ from 'lodash';

export default class RunTestResult {

  constructor(deployResult = {}) {
    _.assign(this, (deployResult.details || {}).runTestResult || {});
    if (!_.isArray(this.failures)) {
      this.failures = _.compact([this.failures]);
    }
  }

  getRecentFailures(old = {}) {
    if (old.numFailures) {
      return this.failures.slice(old.numFailures);
    }
    return [];
  }

  reportFailures(failures = []) {
    if (!failures.length) {
      return;
    }
    const sep = _.repeat('-', 80);
    console.log(sep);
    console.log('Test Failures:');
    failures.forEach((failure, i) => {
      let num;
      const indent = _.repeat(' ', (num = `${i + 1}. `).length);
      console.log(`${num}${failure.name}.${failure.methodName}`);
      console.log(indent + failure.message);
      return failure.stackTrace.split('\n').forEach(line => console.log(`${indent}${line}`));
    });
    return console.log(sep);
  }
}
