import { settings } from './settings.js';

const debug = (...args) => { if (settings.debug) console.debug('rock-sync:', ...args); };

export { debug };
