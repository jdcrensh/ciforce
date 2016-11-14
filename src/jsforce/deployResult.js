import _ from 'lodash';
import ComponentResults from './componentResults';
import RunTestResult from './runTestResult';

export default class DeployResult {

  constructor(data = {}) {
    _.assign(this, data);
    this.runTestResult = new RunTestResult(this);
    this.componentResults = new ComponentResults(this);
  }

  statusMessage() {
    let msg = '';
    let state = this.status || this.state;
    if (state != null) {
      state = (() => {
        switch (state) {
          case 'InProgress': return 'In Progress';
          default: return state;
        } })();
      msg += state + (() => {
        switch (state) {
          case 'Canceled': return ` by ${this.canceledByName}`;
          case 'Canceling': return '';
          default: return (this.stateDetail != null) ? ` -- ${this.stateDetail}` : '';
        } })();
    }
    return msg;
  }

  getRecentFailures(old) {
    return {
      components: this.componentResults.getRecentFailures(old.componentResults),
      tests: this.runTestResult.getRecentFailures(old.runTestResult),
    };
  }

  reportFailures(failures = { tests: [], components: [] }) {
    console.log(failures);
    if (failures.components.length) {
      this.componentResults.reportFailures(failures.components);
    }
    if (failures.tests.length) {
      this.runTestResult.reportFailures(failures.tests);
    }
  }

  report() {
    if (this.success === 'SucceededPartial') {
      console.log('Deployment partially succeeded.');
    } else if (this.success) {
      console.log('Deploy succeeded.');
    } else if (this.done) {
      console.log('Deploy failed.');
    } else {
      console.log('Deploy not completed yet.');
    }
    if (this.errorMessage) {
      console.log(`${this.errorStatusCode}: ${this.errorMessage}`);
    }
    console.log();
    console.log(`Id: ${this.id}`);
    console.log(`Status: ${this.status}`);
    console.log(`Success: ${this.success}`);
    console.log(`Done: ${this.done}`);
    console.log(`Component Errors: ${this.numberComponentErrors}`);
    console.log(`Components Deployed: ${this.numberComponentsDeployed}`);
    console.log(`Components Total: ${this.numberComponentsTotal}`);
    console.log(`Test Errors: ${this.numberTestErrors}`);
    console.log(`Tests Completed: ${this.numberTestsCompleted}`);
    console.log(`Tests Total: ${this.numberTestsTotal}`);
    console.log('');

    const failures = _.compactArray(this.componentFailures);
    if (failures.length) {
      console.log('Failures:');
      failures.forEach(f => console.log(` - ${f.problemType} on ${f.fileName} : ${f.problem}`));
    }

    const successes = _.compactArray(this.componentSuccesses);
    if (successes.length) {
      console.log('Successes:');
      return successes.forEach((s) => {
        const flag = (() => {
          switch (true) {
            case `${s.changed}`: return '(M)';
            case `${s.created}`: return '(A)';
            case `${s.deleted}`: return '(D)';
            default: return '(~)';
          } })();
        return console.log(` - ${flag} ${s.fileName}${s.componentType ? ` [${s.componentType}]` : ''}`);
      });
    }
  }
}
