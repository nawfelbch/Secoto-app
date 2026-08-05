import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const sql = await readFile(
  new URL(
    "../supabase/migrations/202608050008_view_helper_permissions.sql",
    import.meta.url,
  ),
  "utf8",
);

test("les vues PostgREST n'appellent plus directement les helpers privés", () => {
  const adminStart = sql.indexOf(
    "create or replace view public.secoto_missions_admin_v2",
  );
  const publicStart = sql.indexOf(
    "create or replace view public.secoto_public_missions_v2",
  );
  const grantsStart = sql.indexOf(
    "grant select on table public.secoto_missions_admin_v2",
  );

  const adminView = sql.slice(adminStart, publicStart);
  const publicView = sql.slice(publicStart, grantsStart);

  assert.match(adminView, /where public\.secoto_is_admin\(\);/);
  assert.doesNotMatch(adminView, /secoto_private\.is_admin/);

  assert.match(
    publicView,
    /where public\.secoto_current_transporter_matches_mission\(m\.id\);/,
  );
  assert.doesNotMatch(
    publicView,
    /secoto_private\.transporter_matches_mission/,
  );
});

test("les wrappers publics utilisent l'identité authentifiée courante", () => {
  assert.match(
    sql,
    /select secoto_private\.is_admin\(auth\.uid\(\)\);/,
  );
  assert.match(
    sql,
    /secoto_private\.transporter_matches_mission\(\s*auth\.uid\(\),\s*p_mission_id\s*\)/,
  );
  assert.match(sql, /security definer/g);
  assert.match(sql, /set search_path = ''/g);
});

test("seul authenticated peut exécuter les wrappers de visibilité", () => {
  assert.match(
    sql,
    /revoke all on function public\.secoto_is_admin\(\)[\s\S]*?from public, anon;/,
  );
  assert.match(
    sql,
    /grant execute on function public\.secoto_is_admin\(\)[\s\S]*?to authenticated;/,
  );
  assert.match(
    sql,
    /grant execute on function[\s\S]*?secoto_current_transporter_matches_mission\(uuid\)[\s\S]*?to authenticated;/,
  );
});
