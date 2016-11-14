import _ from 'lodash';

export default class ComponentResults {
  constructor(deployResult) {
    this.successes = (deployResult.details || {}).componentSuccesses || [];
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
    console.log('Component Failures:');

    failures.forEach((failure, i) => {
      const num = `${i + 1}. `;
      const indent = _.repeat(' ', num.length);
      console.log(`${num}${failure.name}.${failure.methodName}`);
      console.log(indent + failure.message);
      failure.stackTrace.split('\n').forEach(line => console.log(`${indent}${line}`));
    });
    console.log(sep);
  }
}
