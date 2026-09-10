-- Hello Academy — private media storage
-- Photos of children never sit in a public bucket. Delivery is by signed URL
-- with a short expiry, so a copied link stops working.

insert into storage.buckets (id, name, public)
values ('media', 'media', false)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', false)
on conflict (id) do nothing;

-- objects are keyed  media/{school_id}/{class_id}/{uuid}.{ext}
-- staff upload into classes they teach
create policy media_insert on storage.objects for insert to authenticated
with check (
  bucket_id = 'media'
  and teaches_class(((storage.foldername(name))[2])::uuid)
);

create policy media_delete on storage.objects for delete to authenticated
using (
  bucket_id = 'media'
  and teaches_class(((storage.foldername(name))[2])::uuid)
);

-- reading goes through the media table, not the bucket: a guardian may read an
-- object only if a media row tags one of their children
create policy media_select on storage.objects for select to authenticated
using (
  bucket_id = 'media'
  and exists (
    select 1 from media m
    where m.storage_path = storage.objects.name
      and (
        teaches_class(m.class_id)
        or is_admin()
        or exists (select 1 from unnest(m.student_ids) sid where is_guardian_of(sid))
      )
  )
);

-- avatars are keyed  avatars/{user_or_student_id}.jpg
create policy avatar_select on storage.objects for select to authenticated
using (bucket_id = 'avatars');

create policy avatar_write on storage.objects for insert to authenticated
with check (
  bucket_id = 'avatars'
  and (
    split_part(name,'.',1) = auth.uid()::text
    or is_guardian_of(split_part(name,'.',1)::uuid)
    or teaches_student(split_part(name,'.',1)::uuid)
    or is_admin()
  )
);
