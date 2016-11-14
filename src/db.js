import Loki from 'lokijs';

const FOLDER_OVERRIDES = { EmailTemplate: 'Email' };

const loki = new Loki();

/*
 * git file diffs
 *
 * Model:
 *   path: String; eg. 'src/classes/Calculations.cls'
 *   status: String; eg. 'M'
 *   directory: String; eg. 'classes'
 *   member: String; eg. 'Calculations'
 */
const diff = loki.addCollection('diff');

/**
 * global metadata describe
 */
const metadata = loki.addCollection('metadataDescribe', {
  indices: ['xmlName', 'xmlFolderName', 'directoryName'],
});

metadata.on('pre-insert', (obj) => {
  if (obj.inFolder) {
    let prefix = obj.xmlName;
    if (FOLDER_OVERRIDES[obj.xmlName]) {
      prefix = FOLDER_OVERRIDES[obj.xmlName];
    }
    obj.xmlFolderName = `${prefix}Folder`;
  }
});

/**
 * org components describe
 */
const components = loki.addCollection('componentDescribe', {
  indices: ['fileName'],
});

components.on('pre-insert', (obj) => {
  if (obj.type === 'CustomObjectTranslation') {
    obj.manageableState = (obj.fullName.match(/__.+__c/g) != null) ? 'installed' : 'unmanaged';
  }
  // set member type name used in package xml (i.e. *Folder types)
  const describe = metadata.findObject({ xmlFolderName: obj.type });
  obj.memberType = (describe || {}).xmlName || obj.type;
});

const onUpsert = (obj) => {
  if (obj.manageableState === 'installed') {
    components.remove(obj);
  }
};
components.on('insert', onUpsert);
components.on('update', onUpsert);

/**
 * org sobjects describe
 */
const global = loki.addCollection('globalDescribe');

/**
 * deploy results for components
 */
const componentResult = loki.addCollection('componentResult');

/**
 * deploy results for tests
 */
const runTestResult = loki.addCollection('runTestResult');

// export
export {
  diff,
  metadata,
  components,
  global,
  componentResult,
  runTestResult,
};
