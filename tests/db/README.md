# Tests base de données — migrations 030 à 032

Ces tests s'exécutent sur une base PostgreSQL 17 **jetable**, jamais sur la production.
Le socle Supabase (`auth.uid()`, rôles `anon` / `authenticated` / `service_role`, schéma
`storage`) et la base SECOTO antérieure sont reconstitués à partir des gardes de la
migration 001 : `00_supabase_stub.sql` puis `01_secoto_baseline.sql`, avant de rejouer
l'intégralité de `supabase/migrations/`.

```bash
createdb secoto_test
psql -d secoto_test -v ON_ERROR_STOP=1 -f tests/db/00_supabase_stub.sql
psql -d secoto_test -v ON_ERROR_STOP=1 -f tests/db/01_secoto_baseline.sql
for f in supabase/migrations/*.sql; do psql -d secoto_test -v ON_ERROR_STOP=1 -f "$f" || break; done
npm i --no-save pg
PGURL=postgres://postgres@localhost:5432/secoto_test node --test tests/db/od-subscription-live.dbtest.mjs
```

Couverture : acceptations simultanées (15 commandes × 3 partenaires), webhooks rejoués et
reçus dans le désordre, échec de capture après attribution, absence de partenaire et
restitution du paiement, quotas d'abonnement concurrents, plafond kilométrique, import
d'historique, suivi GPS (position périmée, accès interdit, arrêt à la livraison et à la
réattribution), cloisonnement des prix et des documents, non-régression du paiement à la
livraison existant.

PostgreSQL 17 est nécessaire (la migration 009 utilise `ALTER COLUMN … SET EXPRESSION`).
