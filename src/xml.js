import xmldom from 'xmldom';
import fs from 'fs-extra';
import { pd } from 'pretty-data';
import _ from 'lodash';

export default {
  writePackage(components, version, path, done) {
    const doc = new xmldom.DOMParser().parseFromString('<?xml version="1.0" encoding="UTF-8"?><Package/>');
    doc.documentElement.setAttribute('xmlns', 'http://soap.sforce.com/2006/04/metadata');
    doc.documentElement
      .appendChild(doc.createElement('version'))
      .appendChild(doc.createTextNode(version));

    // sort/uniquify
    components = _(components)
      .mapValues(arr => _.sortBy(arr, v => v.toLowerCase()))
      .mapValues(arr => _.uniq(arr, true))
      .value();

    // build out package dom nodes
    const types = Object.keys(components).sort();
    types.forEach((type) => {
      const type_node = doc.documentElement
        .appendChild(doc.createElement('types'))
        .appendChild(doc.createElement('name'))
        .appendChild(doc.createTextNode(type))
        .parentNode
        .parentNode;
      return components[type].forEach(member =>
        type_node
          .appendChild(doc.createElement('members'))
          .appendChild(doc.createTextNode(member))
      );
    });
    // write xml to file
    return fs.outputFile(path, pd.xml(doc.toString()), done);
  },
};
