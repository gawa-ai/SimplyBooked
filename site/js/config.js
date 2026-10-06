// Public, browser-safe settings only. The publishable key is designed to be public: every table is protected by
// row-level security and every action re-checks the signed-in user's organisation and role in the database.
// Never put a secret key (sb_secret_… / service_role) in this file.
export const CONFIG = Object.freeze({
  supabaseUrl: 'https://jdqidbgjlttojhseyugr.supabase.co',
  publishableKey: 'sb_publishable_xA1tsMpRwLuiJfSrGURtEQ_KTYpyNPt',
  // Shown as a "Book a call" button on the landing page when set, e.g. 'hello@simplybooked.co.uk'. Hidden when empty.
  contactEmail: '',
});
