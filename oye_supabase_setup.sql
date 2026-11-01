-- OYE THRIFT STORE: Supabase database setup
-- Run this entire script in Supabase Dashboard > SQL Editor > New query.
-- Uses Supabase Auth; NEVER put a service_role/secret key in website code.

create extension if not exists pgcrypto;

-- Customer profile and trusted admin role.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  role text not null default 'customer' check (role in ('customer','admin')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Products are shared across every visitor/device.
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  sku text,
  description text,
  price numeric(12,2) not null default 0 check (price >= 0),
  discounted_price numeric(12,2) check (discounted_price is null or discounted_price >= 0),
  category text,
  sizes text[] not null default '{}',
  colours text[] not null default '{}',
  stock integer not null default 0 check (stock >= 0),
  status text not null default 'active' check (status in ('active','draft','out_of_stock')),
  images jsonb not null default '[]'::jsonb,
  is_new_arrival boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists products_sku_unique
  on public.products (sku) where sku is not null and sku <> '';

-- One persistent cart per signed-in customer.
create table if not exists public.carts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  updated_at timestamptz not null default now()
);

create table if not exists public.cart_items (
  id uuid primary key default gen_random_uuid(),
  cart_id uuid not null references public.carts(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  quantity integer not null default 1 check (quantity > 0),
  selected_size text,
  selected_colour text,
  created_at timestamptz not null default now(),
  unique (cart_id, product_id, selected_size, selected_colour)
);

-- Orders retain product details as a snapshot even if a product is later edited/deleted.
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_reference text not null unique default (
    'OYE-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))
  ),
  customer_id uuid not null references auth.users(id) on delete restrict,
  customer_name text,
  customer_email text,
  customer_phone text,
  delivery_address text,
  delivery_city text,
  items jsonb not null default '[]'::jsonb,
  subtotal numeric(12,2) not null default 0 check (subtotal >= 0),
  status text not null default 'received'
    check (status in ('received','confirmed','cancelled','completed')),
  checkout_channel text not null default 'whatsapp'
    check (checkout_channel in ('whatsapp')),
  created_at timestamptz not null default now()
);

create index if not exists orders_customer_created_idx
  on public.orders(customer_id, created_at desc);
create index if not exists products_category_idx on public.products(category);

-- Automatically create a customer profile when someone signs up.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    coalesce(new.raw_user_meta_data ->> 'phone', '')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Keep updated_at current.
create or replace function public.set_updated_at()
returns trigger language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at before update on public.profiles
for each row execute procedure public.set_updated_at();

drop trigger if exists products_set_updated_at on public.products;
create trigger products_set_updated_at before update on public.products
for each row execute procedure public.set_updated_at();

drop trigger if exists carts_set_updated_at on public.carts;
create trigger carts_set_updated_at before update on public.carts
for each row execute procedure public.set_updated_at();

-- Helper checks the trusted profile role. Customers cannot change their own role.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role = 'admin'
  );
$$;

alter table public.profiles enable row level security;
alter table public.products enable row level security;
alter table public.carts enable row level security;
alter table public.cart_items enable row level security;
alter table public.orders enable row level security;

-- Profiles: users can read/update their own basic profile; role is not user-editable.
drop policy if exists "Users read own profile" on public.profiles;
create policy "Users read own profile" on public.profiles
for select to authenticated using (id = (select auth.uid()) or public.is_admin());

drop policy if exists "Users update own profile fields" on public.profiles;
create policy "Users update own profile fields" on public.profiles
for update to authenticated
using (id = (select auth.uid()) or public.is_admin())
with check (id = (select auth.uid()) or public.is_admin());

-- Products: everyone can view active products; admins manage the catalogue.
drop policy if exists "Public read active products" on public.products;
create policy "Public read active products" on public.products
for select to anon, authenticated
using (status = 'active' or public.is_admin());

drop policy if exists "Admins insert products" on public.products;
create policy "Admins insert products" on public.products
for insert to authenticated with check (public.is_admin());

drop policy if exists "Admins update products" on public.products;
create policy "Admins update products" on public.products
for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Admins delete products" on public.products;
create policy "Admins delete products" on public.products
for delete to authenticated using (public.is_admin());

-- Carts and cart items are private to their owner (or visible to admins).
drop policy if exists "Users manage own carts" on public.carts;
create policy "Users manage own carts" on public.carts
for all to authenticated
using (user_id = (select auth.uid()) or public.is_admin())
with check (user_id = (select auth.uid()) or public.is_admin());

drop policy if exists "Users manage own cart items" on public.cart_items;
create policy "Users manage own cart items" on public.cart_items
for all to authenticated
using (
  exists (
    select 1 from public.carts c
    where c.id = cart_id and (c.user_id = (select auth.uid()) or public.is_admin())
  )
)
with check (
  exists (
    select 1 from public.carts c
    where c.id = cart_id and (c.user_id = (select auth.uid()) or public.is_admin())
  )
);

-- Customers can create/read their own orders; only admins can update/delete them.
drop policy if exists "Customers read own orders" on public.orders;
create policy "Customers read own orders" on public.orders
for select to authenticated
using (customer_id = (select auth.uid()) or public.is_admin());

drop policy if exists "Customers create own orders" on public.orders;
create policy "Customers create own orders" on public.orders
for insert to authenticated
with check (customer_id = (select auth.uid()));

drop policy if exists "Admins update orders" on public.orders;
create policy "Admins update orders" on public.orders
for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "Admins delete orders" on public.orders;
create policy "Admins delete orders" on public.orders
for delete to authenticated using (public.is_admin());

-- Product image storage. Upload images to this bucket and save their public URLs
-- in products.images (JSON array). Public can view; only admins can upload/change/delete.
insert into storage.buckets (id, name, public)
values ('oye-product-images', 'oye-product-images', true)
on conflict (id) do update set public = true;

drop policy if exists "Anyone can view OYE product images" on storage.objects;
create policy "Anyone can view OYE product images" on storage.objects
for select to anon, authenticated
using (bucket_id = 'oye-product-images');

drop policy if exists "Admins upload OYE product images" on storage.objects;
create policy "Admins upload OYE product images" on storage.objects
for insert to authenticated
with check (bucket_id = 'oye-product-images' and public.is_admin());

drop policy if exists "Admins update OYE product images" on storage.objects;
create policy "Admins update OYE product images" on storage.objects
for update to authenticated
using (bucket_id = 'oye-product-images' and public.is_admin())
with check (bucket_id = 'oye-product-images' and public.is_admin());

drop policy if exists "Admins delete OYE product images" on storage.objects;
create policy "Admins delete OYE product images" on storage.objects
for delete to authenticated
using (bucket_id = 'oye-product-images' and public.is_admin());

-- IMPORTANT: After the owner has signed up once, promote their account to admin.
-- Replace OWNER_AUTH_USER_UUID with the owner's Auth user UUID from
-- Supabase Dashboard > Authentication > Users, then run:
-- update public.profiles set role = 'admin' where id = 'OWNER_AUTH_USER_UUID';
--
-- Do not allow the website to set role='admin' during signup/profile editing.
