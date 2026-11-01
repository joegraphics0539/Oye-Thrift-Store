
-- OYE THRIFT STORE - COMPLETE SUPABASE SETUP
-- Run this in https://supabase.com/dashboard/project/meiaeeuanamlvfyyprhn/sql/new

-- 1. PROFILES (extends auth.users)
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  email text,
  phone text,
  role text default 'customer' check (role in ('customer','admin')),
  created_at timestamp with time zone default now(),
  updated_at timestamp with time zone default now()
);

-- 2. PRODUCTS - CENTRAL SOURCE OF TRUTH
create table if not exists products (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  sku text not null unique,
  description text,
  price numeric not null,
  discounted_price numeric,
  category text check (category in ('men','women','unisex','accessories')),
  images text[] default '{}',
  sizes text[] default '{}',
  colours text[] default '{}',
  stock int default 0,
  status text default 'IN STOCK' check (status in ('IN STOCK','LIMITED STOCK','OUT OF STOCK','SOLD OUT')),
  featured boolean default false,
  new_arrival boolean default false,
  is_published boolean default true,
  created_at timestamp with time zone default now(),
  updated_at timestamp with time zone default now()
);

-- 3. CARTS
create table if not exists carts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade unique,
  created_at timestamp with time zone default now(),
  updated_at timestamp with time zone default now()
);

-- 4. CART ITEMS
create table if not exists cart_items (
  id uuid primary key default gen_random_uuid(),
  cart_id uuid references carts(id) on delete cascade,
  product_id uuid references products(id) on delete cascade,
  quantity int default 1,
  selected_size text,
  selected_colour text,
  created_at timestamp with time zone default now(),
  unique(cart_id, product_id, selected_size, selected_colour)
);

-- 5. ORDERS
create table if not exists orders (
  id uuid primary key default gen_random_uuid(),
  order_ref text unique not null,
  customer_id uuid references auth.users(id) on delete set null,
  customer_name text,
  customer_email text,
  customer_phone text,
  products jsonb not null,
  total numeric not null,
  status text default 'Checkout Initiated' check (status in ('Checkout Initiated','WhatsApp Opened','Order Confirmed','Payment Confirmed','Delivered','Cancelled')),
  created_at timestamp with time zone default now(),
  updated_at timestamp with time zone default now()
);

-- Enable RLS
alter table profiles enable row level security;
alter table products enable row level security;
alter table carts enable row level security;
alter table cart_items enable row level security;
alter table orders enable row level security;

-- Drop existing policies if rerunning
drop policy if exists "Public can read published products" on products;
drop policy if exists "Admin can manage products" on products;
drop policy if exists "Users can manage own profile" on profiles;
drop policy if exists "Admin can view all profiles" on profiles;
drop policy if exists "Users manage own cart" on carts;
drop policy if exists "Users manage own cart items" on cart_items;
drop policy if exists "Users can insert own orders" on orders;
drop policy if exists "Users can view own orders" on orders;
drop policy if exists "Admin can view all orders" on orders;

-- PRODUCTS: Public read published, Admin write
create policy "Public can read published products"
on products for select using (is_published = true);

create policy "Admin can manage products"
on products for all using (
  exists (select 1 from profiles where profiles.id = auth.uid() and profiles.role = 'admin')
);

-- Allow anon read for shop (needed before login)
create policy "Anon can read products" on products for select using (true);

-- PROFILES
create policy "Users can manage own profile"
on profiles for all using (auth.uid() = id);

create policy "Admin can view all profiles"
on profiles for select using (
  exists (select 1 from profiles where profiles.id = auth.uid() and profiles.role = 'admin')
);

-- CARTS
create policy "Users manage own cart"
on carts for all using (auth.uid() = user_id);

-- CART ITEMS (via cart ownership)
create policy "Users manage own cart items"
on cart_items for all using (
  exists (select 1 from carts where carts.id = cart_items.cart_id and carts.user_id = auth.uid())
);

-- ORDERS
create policy "Users can insert own orders"
on orders for insert with check (auth.uid() = customer_id);

create policy "Users can view own orders"
on orders for select using (auth.uid() = customer_id);

create policy "Admin can view all orders"
on orders for select using (
  exists (select 1 from profiles where profiles.id = auth.uid() and profiles.role = 'admin')
);

create policy "Admin can update orders"
on orders for update using (
  exists (select 1 from profiles where profiles.id = auth.uid() and profiles.role = 'admin')
);

-- Storage bucket for product images
insert into storage.buckets (id, name, public)
values ('oye-product-images', 'oye-product-images', true)
on conflict (id) do nothing;

-- Storage policies
drop policy if exists "Public read product images" on storage.objects;
drop policy if exists "Admin upload product images" on storage.objects;
drop policy if exists "Admin delete product images" on storage.objects;

create policy "Public read product images"
on storage.objects for select using (bucket_id = 'oye-product-images');

create policy "Admin upload product images"
on storage.objects for insert with check (
  bucket_id = 'oye-product-images' and
  exists (select 1 from profiles where profiles.id = auth.uid() and profiles.role = 'admin')
);

create policy "Admin delete product images"
on storage.objects for delete using (
  bucket_id = 'oye-product-images' and
  exists (select 1 from profiles where profiles.id = auth.uid() and profiles.role = 'admin')
);

-- Function to auto-create profile on signup
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    case when new.email = 'yetqueen11@gmail.com' then 'admin' else 'customer' end
  );
  
  insert into public.carts (user_id) values (new.id);
  
  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Update updated_at trigger
create or replace function update_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists products_updated_at on products;
create trigger products_updated_at before update on products for each row execute procedure update_updated_at();

-- Create admin profile for existing owner if not exists (run after owner signs up)
-- insert into profiles (id, email, role) values (auth.uid(), 'yetqueen11@gmail.com', 'admin') on conflict do update set role='admin';

