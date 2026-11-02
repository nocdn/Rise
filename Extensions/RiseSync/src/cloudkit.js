export const CONTAINER = 'iCloud.dev.bartosz.Rise';
export const ZONE = {zoneName:'RiseSharedTabs'};
export class CloudError extends Error {
  constructor(data = {}) {
    const code = data.serverErrorCode ?? 'NETWORK';
    const messages = {
      AUTHENTICATION_REQUIRED:'Sign in to iCloud to continue.', AUTHENTICATION_FAILED:'Your iCloud sign-in expired. Sign in again.',
      ACCESS_DENIED:'iCloud denied access. Check the API token and its allowed origin in CloudKit Console.',
      QUOTA_EXCEEDED:'Your iCloud storage is full. Changes are saved here for later.',
      THROTTLED:'iCloud is busy. Your changes will retry automatically.',
      BAD_REQUEST:'Check the CloudKit API token and environment in Settings.',
      ZONE_NOT_FOUND:'Open Rise with iCloud sync enabled first, then try again.',
    };
    super(messages[code] ?? 'Could not sync with iCloud. Your changes are saved here for retry.');
    this.code = code; this.redirectURL = data.redirectURL;
    this.retryAfter = Math.min(3600, Math.max(0, Number(data.retryAfter) || 0));
  }
}
// Requests are deliberately serial: Apple rotates the web authentication token.
export class CloudKit {
  constructor(config, auth, saveAuth, fetcher = fetch) { this.config = config; this.zone = {zoneName:config.zoneName ?? ZONE.zoneName}; this.auth = auth; this.saveAuth = saveAuth; this.fetcher = fetcher; }
  async request(path, body, database = 'private') {
    const url = new URL(`https://api.apple-cloudkit.com/database/1/${CONTAINER}/${this.config.environment}/${database}/${path}`);
    url.searchParams.set('ckAPIToken', this.config.apiToken);
    if (this.auth.token) url.searchParams.set('ckWebAuthToken', this.auth.token);
    let response, data;
    try {
      // WebIDL fetch requires the global receiver in Chromium workers.
      const fetcher = this.fetcher.bind(globalThis);
      response = await fetcher(url.href, {method:body === undefined ? 'GET' : 'POST',
        ...(body === undefined ? {} : {headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}),
        credentials:'omit', cache:'no-store', redirect:'error', signal:AbortSignal.timeout(20000)});
      data = await response.json();
    } catch { throw new CloudError(); }
    const rotated = response.headers.get('x-apple-cloudkit-web-auth-token') ?? response.headers.get('x-apple-cloudkit-session') ?? data.ckWebAuthToken;
    if (rotated) { this.auth.token = rotated; await this.saveAuth(); }
    if (data.serverErrorCode) throw new CloudError(data);
    if (!response.ok) throw new CloudError();
    return data;
  }
  // Apple exposes current-user identity on the public database endpoint.
  user() { return this.request('users/caller', undefined, 'public'); }
  async changes(token) {
    const data = await this.request('changes/zone', {zones:[{zoneID:this.zone, ...(token ? {syncToken:token} : {})}],
      desiredRecordTypes:['RiseTab'], desiredKeys:['payload'], resultsLimit:200});
    const zone = data.zones?.[0];
    if (!zone) throw new CloudError();
    if (zone.serverErrorCode) throw new CloudError(zone);
    return zone;
  }
  async modify(operations) {
    const data = await this.request('records/modify', {zoneID:this.zone, atomic:false, operations});
    if (!Array.isArray(data.records)) throw new CloudError();
    return data.records;
  }
  async lookup(ids) {
    const data = await this.request('records/lookup', {zoneID:this.zone, records:ids.map(recordName => ({recordName}))});
    if (!Array.isArray(data.records)) throw new CloudError();
    return data.records;
  }
}
export function authTokenFromRedirect(raw, callback) {
  const u = new URL(raw), expected = new URL(callback);
  if (u.origin !== expected.origin || u.pathname !== expected.pathname) throw new Error('Unexpected iCloud sign-in callback.');
  const token = u.searchParams.get('ckSession') ?? u.searchParams.get('ckWebAuthToken') ?? new URLSearchParams(u.hash.slice(1)).get('ckWebAuthToken');
  if (!token || token.length > 16384) throw new Error('iCloud did not return a sign-in token.');
  return token;
}
