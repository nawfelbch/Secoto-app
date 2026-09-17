const chain = () => ({ select: chain, eq: chain, maybeSingle: async () => ({ data: null }), single: async () => ({ data: null }), upload: async () => ({ error: null }) });
export const supabase = {
  rpc: async () => ({ data: null, error: null }),
  from: () => chain(),
  storage: { from: () => chain() },
  auth: { getSession: async () => ({ data: { session: null } }) },
  channel: () => ({ on() { return this; }, subscribe() { return this; } }),
  removeChannel: () => {},
};
export const supabaseUrl = "https://stub.invalid";
export const supabaseAnonKey = "stub";
