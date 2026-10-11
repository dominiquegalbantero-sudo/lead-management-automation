begin;

select plan(7);

select lives_ok(
  $$select public.upsert_lead(
    'test-duplicate-001',
    'Original Name',
    'lead-duplicate-test@example.com',
    'Original Company',
    'Partner'
  )$$,
  'the first lead can be stored'
);

select lives_ok(
  $$select public.upsert_lead(
    'test-duplicate-001',
    'Updated Name',
    'lead-duplicate-test@example.com',
    'Updated Company',
    'Partner'
  )$$,
  'resubmitting the same partner ID updates the lead'
);

select is(
  (select count(*)::integer from public.leads where external_id = 'test-duplicate-001'),
  1,
  'duplicate partner submissions do not create a second row'
);

select is(
  (select name from public.leads where external_id = 'test-duplicate-001'),
  'Updated Name',
  'the duplicate submission updates lead details'
);

select lives_ok(
  $$select public.upsert_lead(
    'test-email-update-002',
    'Email Match Name',
    ' LEAD-DUPLICATE-TEST@example.com ',
    'Email Match Company',
    'Website'
  )$$,
  'a new partner ID with an existing email updates the existing lead'
);

select is(
  (select count(*)::integer from public.leads where lower(trim(email)) = 'lead-duplicate-test@example.com'),
  1,
  'matching email addresses remain unique'
);

select is(
  (select external_id from public.leads where lower(trim(email)) = 'lead-duplicate-test@example.com'),
  'test-email-update-002',
  'the existing email record receives the latest partner ID'
);

select * from finish();
rollback;
