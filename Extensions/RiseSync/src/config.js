// Public web client identifiers, intended to ship in clients. These are not server
// keys or user credentials. Private data always requires Apple Account sign-in.
export const API_TOKENS = {
  development:'ba8862c0efcf5e7d1d3acb0ff0b5bdaad224ccb11775a1f4453747669fea95f3',
  production:'5b911f48e70b18c2f2a672516ae925753d9c8a8708c7c563cdf165cb011106f8'
};
// The installed Mac build uses Production. Xcode development builds may use Development.
export const DEFAULT_CONFIG = {apiToken:API_TOKENS.production,environment:'production'};
