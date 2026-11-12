-- BhoomiSetu PostgreSQL schema for Supabase
-- Run in Supabase SQL Editor. Auth identities live in auth.users; profiles store app roles.
create extension if not exists pgcrypto;
create type public.app_role as enum ('farmer','staff','admin');
create type public.booking_status as enum ('BOOKED','CHECKED IN','WAITING IN QUEUE','CALLED FOR PROCUREMENT','PROCUREMENT IN PROGRESS','QUALITY CHECK','WEIGHMENT COMPLETED','PROCUREMENT COMPLETED','CANCELLED','MISSED SLOT');

create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 role public.app_role not null default 'farmer',
 full_name text not null,
 mobile text not null unique,
 village text, mandal text, district text, state text default 'Telangana',
 farmer_id text, landholding text, preferred_language text default 'English',
 created_at timestamptz not null default now()
);
create table if not exists public.procurement_centres (
 id uuid primary key default gen_random_uuid(), centre_code text unique not null,
 name text not null, village text, mandal text, district text not null, state text not null default 'Telangana',
 address text not null, crops text[] not null default '{}', operating_days text[] not null default '{Monday,Tuesday,Wednesday,Thursday,Friday,Saturday}',
 opens_at time not null default '09:00', closes_at time not null default '17:00', daily_capacity integer not null default 80 check(daily_capacity>0),
 phone text, status text not null default 'Open' check(status in ('Open','Closed','Temporarily Unavailable')),
 created_at timestamptz not null default now()
);
create table if not exists public.centre_staff (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 centre_id uuid not null references public.procurement_centres(id) on delete cascade, unique(user_id,centre_id)
);
create table if not exists public.crops (
 id uuid primary key default gen_random_uuid(), name text unique not null, is_active boolean not null default true
);
create table if not exists public.time_slots (
 id uuid primary key default gen_random_uuid(), centre_id uuid not null references public.procurement_centres(id) on delete cascade,
 slot_date date not null, starts_at time not null, ends_at time not null, capacity integer not null default 10 check(capacity>0), is_open boolean not null default true,
 unique(centre_id,slot_date,starts_at), check(ends_at>starts_at)
);
create table if not exists public.bookings (
 id uuid primary key default gen_random_uuid(), booking_code text unique not null,
 farmer_id uuid not null references public.profiles(id), centre_id uuid not null references public.procurement_centres(id),
 slot_id uuid not null references public.time_slots(id), crop text not null, quantity_kg numeric(12,2) not null check(quantity_kg>0),
 token text unique not null, status public.booking_status not null default 'BOOKED', operational_remarks text,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(farmer_id,slot_id)
);
create index if not exists bookings_centre_slot_idx on public.bookings(centre_id,slot_id,status);
create index if not exists bookings_farmer_created_idx on public.bookings(farmer_id,created_at desc);
create table if not exists public.queue_entries (
 id uuid primary key default gen_random_uuid(), booking_id uuid not null unique references public.bookings(id) on delete cascade,
 queue_number bigint generated always as identity, checked_in_at timestamptz, called_at timestamptz, completed_at timestamptz,
 estimated_wait_minutes integer, updated_at timestamptz not null default now()
);
create table if not exists public.notifications (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 title text not null, body text not null, read_at timestamptz, created_at timestamptz not null default now()
);
create table if not exists public.announcements (
 id uuid primary key default gen_random_uuid(), centre_id uuid references public.procurement_centres(id),
 title text not null, body text not null, created_by uuid references public.profiles(id), created_at timestamptz not null default now(), active boolean not null default true
);
create table if not exists public.procurement_records (
 id uuid primary key default gen_random_uuid(), booking_id uuid not null unique references public.bookings(id),
 actual_quantity_kg numeric(12,2), quality_grade text, weighment_reference text, completed_at timestamptz
);
create table if not exists public.audit_logs (
 id uuid primary key default gen_random_uuid(), actor_id uuid references public.profiles(id), action text not null,
 entity_type text not null, entity_id uuid, details jsonb not null default '{}', created_at timestamptz not null default now()
);

create or replace function public.current_role() returns public.app_role language sql stable security definer set search_path=public as $$ select role from public.profiles where id=auth.uid() $$;
create or replace function public.is_centre_staff(p_centre uuid) returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from public.centre_staff where user_id=auth.uid() and centre_id=p_centre) or public.current_role()='admin' $$;

-- Atomically re-check slot capacity and create a booking. The slot row lock prevents two users taking the final place.
create or replace function public.create_booking(p_slot_id uuid,p_crop text,p_quantity_kg numeric)
returns table(booking_id uuid,booking_code text,token text) language plpgsql security definer set search_path=public as $$
declare s public.time_slots; c public.procurement_centres; booked integer; next_code text; next_token text; new_id uuid;
begin
 if auth.uid() is null then raise exception 'Please sign in to book a slot'; end if;
 if public.current_role() <> 'farmer' then raise exception 'Only farmer accounts can create bookings'; end if;
 select * into s from public.time_slots where id=p_slot_id for update;
 if not found or not s.is_open or s.slot_date < current_date then raise exception 'This slot is not available'; end if;
 select * into c from public.procurement_centres where id=s.centre_id;
 if c.status <> 'Open' then raise exception 'This procurement centre is not accepting bookings'; end if;
 if not (p_crop = any(c.crops)) then raise exception 'This crop is not supported at this centre'; end if;
 select count(*) into booked from public.bookings where slot_id=s.id and status <> 'CANCELLED';
 if booked >= s.capacity then raise exception 'Sorry! This slot is already booked and no more bookings are available. Please select another time slot.'; end if;
 if exists(select 1 from public.bookings where farmer_id=auth.uid() and slot_id=s.id and status not in ('CANCELLED','MISSED SLOT')) then raise exception 'You already have a booking for this slot'; end if;
 next_code := 'BHOOMI-'||to_char(current_date,'YYYY')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
 next_token := 'BS-'||c.centre_code||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,5));
 insert into public.bookings(booking_code,farmer_id,centre_id,slot_id,crop,quantity_kg,token) values(next_code,auth.uid(),s.centre_id,p_crop,p_quantity_kg,next_token) returning id into new_id;
 insert into public.queue_entries(booking_id) values(new_id);
 insert into public.notifications(user_id,title,body) values(auth.uid(),'Booking confirmed','Your token '||next_token||' is confirmed at '||c.name||'.');
 insert into public.audit_logs(actor_id,action,entity_type,entity_id) values(auth.uid(),'booking.created','booking',new_id);
 return query select new_id,next_code,next_token;
end; $$;

alter table public.profiles enable row level security;
alter table public.procurement_centres enable row level security;
alter table public.centre_staff enable row level security;
alter table public.crops enable row level security;
alter table public.time_slots enable row level security;
alter table public.bookings enable row level security;
alter table public.queue_entries enable row level security;
alter table public.notifications enable row level security;
alter table public.announcements enable row level security;
alter table public.procurement_records enable row level security;
alter table public.audit_logs enable row level security;

create policy "profiles read self or staff admin" on public.profiles for select using(id=auth.uid() or public.current_role()='admin' or exists(select 1 from public.centre_staff cs join public.bookings b on b.farmer_id=profiles.id where cs.user_id=auth.uid() and b.centre_id=cs.centre_id));
create policy "profile self insert" on public.profiles for insert with check(id=auth.uid() and role='farmer');
create policy "profile self update" on public.profiles for update using(id=auth.uid() or public.current_role()='admin') with check(id=auth.uid() or public.current_role()='admin');
create policy "centres public read" on public.procurement_centres for select using(true);
create policy "centres admin write" on public.procurement_centres for all using(public.current_role()='admin') with check(public.current_role()='admin');
create policy "staff assignments admin manage" on public.centre_staff for all using(public.current_role()='admin' or user_id=auth.uid()) with check(public.current_role()='admin');
create policy "crops public read" on public.crops for select using(true);
create policy "crops admin manage" on public.crops for all using(public.current_role()='admin') with check(public.current_role()='admin');
create policy "slots public read" on public.time_slots for select using(true);
create policy "slots admin manage" on public.time_slots for all using(public.current_role()='admin') with check(public.current_role()='admin');
create policy "booking farmer or assigned staff read" on public.bookings for select using(farmer_id=auth.uid() or public.is_centre_staff(centre_id));
create policy "booking staff update" on public.bookings for update using(public.is_centre_staff(centre_id)) with check(public.is_centre_staff(centre_id));
create policy "queue farmer or staff read" on public.queue_entries for select using(exists(select 1 from public.bookings b where b.id=booking_id and (b.farmer_id=auth.uid() or public.is_centre_staff(b.centre_id))));
create policy "queue staff update" on public.queue_entries for update using(exists(select 1 from public.bookings b where b.id=booking_id and public.is_centre_staff(b.centre_id)));
create policy "notifications owner read" on public.notifications for select using(user_id=auth.uid() or public.current_role()='admin');
create policy "notifications owner update" on public.notifications for update using(user_id=auth.uid()) with check(user_id=auth.uid());
create policy "announcements read" on public.announcements for select using(active=true);
create policy "announcements staff create" on public.announcements for insert with check(public.current_role() in ('staff','admin') and (centre_id is null or public.is_centre_staff(centre_id)));
create policy "procurement records read" on public.procurement_records for select using(exists(select 1 from public.bookings b where b.id=booking_id and (b.farmer_id=auth.uid() or public.is_centre_staff(b.centre_id))));
create policy "procurement records staff manage" on public.procurement_records for all using(exists(select 1 from public.bookings b where b.id=booking_id and public.is_centre_staff(b.centre_id))) with check(exists(select 1 from public.bookings b where b.id=booking_id and public.is_centre_staff(b.centre_id)));
create policy "audit admin read" on public.audit_logs for select using(public.current_role()='admin');

-- New auth users receive a farmer profile by default. Promote staff/admin explicitly from the trusted SQL editor.
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into public.profiles(id,role,full_name,mobile,village,mandal,district,state,preferred_language)
 values(new.id,'farmer',coalesce(new.raw_user_meta_data->>'name','Farmer'),coalesce(new.phone,new.raw_user_meta_data->>'mobile'),new.raw_user_meta_data->>'village',new.raw_user_meta_data->>'mandal',new.raw_user_meta_data->>'district',coalesce(new.raw_user_meta_data->>'state','Telangana'),coalesce(new.raw_user_meta_data->>'preferred_language','English'));
 return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

insert into public.crops(name) values ('Paddy'),('Cotton'),('Maize'),('Red Gram'),('Soybean'),('Turmeric') on conflict do nothing;

-- Fictional starter centres and daily half-hour slots for the first 30 days.
insert into public.procurement_centres(centre_code,name,village,district,state,address,crops,opens_at,closes_at,daily_capacity,phone,status)
values
 ('WGL-01','Warangal Procurement Centre','Enumamula','Warangal','Telangana','Enumamula Market Yard, Warangal, Telangana',array['Paddy','Cotton','Maize'],'09:00','17:00',80,'+91 870 245 1100','Open'),
 ('HNK-02','Hanamkonda Farmers Hub','Kazipet','Hanamkonda','Telangana','Market Road, Kazipet, Telangana',array['Paddy','Cotton','Red Gram'],'09:00','16:30',60,'+91 870 246 2200','Open'),
 ('KMM-03','Khammam Agri Collection Centre','Madhira','Khammam','Telangana','Agricultural Market, Madhira, Telangana',array['Paddy','Maize','Soybean','Turmeric'],'08:30','17:00',72,'+91 874 250 3300','Open')
on conflict(centre_code) do nothing;
insert into public.time_slots(centre_id,slot_date,starts_at,ends_at,capacity)
select c.id,d::date,t::time,(t::time + interval '30 minutes')::time,10
from public.procurement_centres c
cross join generate_series(current_date,current_date+30,interval '1 day') d
cross join generate_series(time '09:00',time '15:30',interval '30 minutes') t
where c.centre_code in ('WGL-01','HNK-02','KMM-03')
on conflict(centre_id,slot_date,starts_at) do nothing;
