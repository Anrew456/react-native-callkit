--
-- PostgreSQL database dump
--

\restrict bbMBYblBny5ln0be37ffUDg3bObGgblPfH6z8d5m9A70riBNf5WplxfcBBTJTIN

-- Dumped from database version 17.6
-- Dumped by pg_dump version 18.3

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: pg_database_owner
--

CREATE SCHEMA public;


ALTER SCHEMA public OWNER TO pg_database_owner;

--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: pg_database_owner
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: clear_all_data(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.clear_all_data() RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
BEGIN
    -- Disable triggers temporarily to avoid slot capacity updates etc.
    SET session_replication_role = replica;

    -- Clear dependent tables first (lowest level)
    TRUNCATE TABLE
        pizza_customizations,
        order_pizzas,
        order_products,
        orders,
        slot_availability,
        slot_config,
        pizza_ingredients,
        pizzeria_ingredients,
        pizzeria_products,
        pizzerias
    RESTART IDENTITY CASCADE;

    -- Keep pizza_sizes data (initial constants)
    -- So we do NOT truncate pizza_sizes.

    -- Restore normal trigger behavior
    SET session_replication_role = DEFAULT;

    RAISE NOTICE '✅ All inserted data cleared successfully (pizza_sizes preserved).';
END;
$$;


ALTER FUNCTION public.clear_all_data() OWNER TO postgres;

--
-- Name: generate_daily_slots(integer, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.generate_daily_slots(p_pizzeria_id integer, p_date date) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE
    v_weekday INTEGER;
    r_config RECORD;
BEGIN
    v_weekday := EXTRACT(DOW FROM p_date);

    FOR r_config IN 
        SELECT * FROM slot_config 
        WHERE pizzeria_id = p_pizzeria_id 
        AND weekday = v_weekday 
        AND active = true
    LOOP
        INSERT INTO slot_availability (
            pizzeria_id, date, start_time, end_time, 
            total_capacity, used_capacity
        ) VALUES (
            p_pizzeria_id, 
            p_date, 
            r_config.start_time, 
            r_config.end_time,
            COALESCE(r_config.pizza_capacity, 
                (SELECT default_slot_capacity FROM pizzerias WHERE id = p_pizzeria_id)),
            0
        ) ON CONFLICT (pizzeria_id, date, start_time) DO NOTHING;
    END LOOP;
END;
$$;


ALTER FUNCTION public.generate_daily_slots(p_pizzeria_id integer, p_date date) OWNER TO postgres;

--
-- Name: FUNCTION generate_daily_slots(p_pizzeria_id integer, p_date date); Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON FUNCTION public.generate_daily_slots(p_pizzeria_id integer, p_date date) IS 'Automatically generates slots for a specific day based on configuration';


--
-- Name: generate_slots_for_days(integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.generate_slots_for_days(p_pizzeria_id integer, p_days integer) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE
    v_current_date DATE;
    v_end_date DATE;
BEGIN
    v_current_date := CURRENT_DATE;
    v_end_date := CURRENT_DATE + p_days;

    WHILE v_current_date < v_end_date LOOP
        -- Call the existing generate_daily_slots function for each day
        PERFORM generate_daily_slots(p_pizzeria_id, v_current_date);
        v_current_date := v_current_date + 1;
    END LOOP;
END;
$$;


ALTER FUNCTION public.generate_slots_for_days(p_pizzeria_id integer, p_days integer) OWNER TO postgres;

--
-- Name: generate_tomorrow_slots(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.generate_tomorrow_slots() RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
DECLARE
    v_tomorrow DATE;
    v_weekday INTEGER;
BEGIN
    -- Calculate tomorrow's date and weekday
    v_tomorrow := CURRENT_DATE + 1;
    v_weekday := EXTRACT(DOW FROM v_tomorrow);

    -- Generate slots for all active pizzerias
    INSERT INTO slot_availability (
        pizzeria_id,
        date,
        start_time,
        end_time,
        total_capacity,
        used_capacity
    )
    SELECT
        sc.pizzeria_id,
        v_tomorrow,
        sc.start_time,
        sc.end_time,
        COALESCE(sc.pizza_capacity, p.default_slot_capacity),
        0
    FROM slot_config sc
    INNER JOIN pizzerias p ON sc.pizzeria_id = p.id
    WHERE sc.weekday = v_weekday
        AND sc.active = true
        AND p.active = true
    ON CONFLICT (pizzeria_id, date, start_time) DO NOTHING;

    RAISE NOTICE 'Slots generated for tomorrow: %', v_tomorrow;
END;
$$;


ALTER FUNCTION public.generate_tomorrow_slots() OWNER TO postgres;

--
-- Name: get_my_pizzeria_ids(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.get_my_pizzeria_ids() RETURNS TABLE(pizzeria_id integer)
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
BEGIN
  -- Pizzerie di cui si è admin (comportamento originale)
  RETURN QUERY
  SELECT pa.pizzeria_id
  FROM public.pizzeria_admins pa
  WHERE pa.user_id = auth.uid();

  -- Pizzeria sorgente menù per il test mode
  RETURN QUERY
  SELECT p.test_source_pizzeria_id
  FROM public.pizzeria_admins pa
  JOIN public.pizzerias p ON p.id = pa.pizzeria_id
  WHERE pa.user_id = auth.uid()
    AND p.test_source_pizzeria_id IS NOT NULL;
END;
$$;


ALTER FUNCTION public.get_my_pizzeria_ids() OWNER TO postgres;

--
-- Name: is_operator_busy(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.is_operator_busy(p_user_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
    SELECT EXISTS (
        SELECT 1 FROM public.handoff_requests
        WHERE claimed_by = p_user_id
          AND status IN ('claimed','in_progress')
    );
$$;


ALTER FUNCTION public.is_operator_busy(p_user_id uuid) OWNER TO postgres;

--
-- Name: populate_customer_from_order(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.populate_customer_from_order() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.customer_phone IS NOT NULL
       AND NEW.customer_address IS NOT NULL
       AND NOT NEW.is_partial
    THEN
        INSERT INTO customers (
            pizzeria_id, phone, name, address,
            latitude, longitude, linked_order_id
        )
        VALUES (
            NEW.pizzeria_id,
            NEW.customer_phone,
            NEW.customer_name,
            NEW.customer_address,
            NEW.customer_latitude,
            NEW.customer_longitude,
            NEW.id
        )
        ON CONFLICT (pizzeria_id, phone, address) DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.populate_customer_from_order() OWNER TO postgres;

--
-- Name: recalculate_all_slot_capacities(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.recalculate_all_slot_capacities() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
  -- Reset all to 0
  UPDATE slot_availability SET used_capacity = 0;

  -- Recalculate from pizzas
  UPDATE slot_availability sa
  SET used_capacity = COALESCE((
    SELECT SUM(op.quantity * COALESCE(ps.capacity_multiplier, 1))
    FROM orders o
    JOIN order_pizzas op ON op.order_id = o.id
    JOIN pizzeria_products pp ON pp.id = op.pizzeria_product_id
    LEFT JOIN pizza_sizes ps ON pp.size_id = ps.id
    WHERE o.slot_id = sa.id
  ), 0) + COALESCE((
    -- Add products
    SELECT SUM(op.quantity * COALESCE(pp.capacity_multiplier, 0))
    FROM orders o
    JOIN order_products op ON op.order_id = o.id
    JOIN pizzeria_products pp ON pp.id = op.pizzeria_product_id
    WHERE o.slot_id = sa.id
  ), 0);

  RAISE NOTICE 'Recalculated all slot capacities';
END;
$$;


ALTER FUNCTION public.recalculate_all_slot_capacities() OWNER TO postgres;

--
-- Name: set_created_at_column(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_created_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.created_at IS NULL THEN
        NEW.created_at = NOW() AT TIME ZONE 'Europe/Rome';
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.set_created_at_column() OWNER TO postgres;

--
-- Name: sync_customer_on_order_update(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sync_customer_on_order_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$BEGIN
    -- Case 1: partial order just confirmed (is_partial: TRUE → FALSE)
    -- Insert customer record with same logic as populate_customer_from_order.
    IF OLD.is_partial = TRUE AND NEW.is_partial = FALSE
       AND NEW.customer_phone IS NOT NULL
       AND NEW.customer_address IS NOT NULL
    THEN
        INSERT INTO public.customers (
            pizzeria_id, phone, name, address,
            latitude, longitude, linked_order_id
        )
        VALUES (
            NEW.pizzeria_id,
            NEW.customer_phone,
            NEW.customer_name,
            NEW.customer_address,
            NEW.customer_latitude,
            NEW.customer_longitude,
            NEW.id
        )
        ON CONFLICT (pizzeria_id, phone, address) DO NOTHING;
    END IF;

    -- Case 2: address corrected on an existing confirmed order
    IF OLD.customer_address IS DISTINCT FROM NEW.customer_address OR OLD.customer_name IS DISTINCT FROM NEW.customer_name THEN
        UPDATE public.customers
        SET
            address   = NEW.customer_address,
            latitude  = NEW.customer_latitude,
            longitude = NEW.customer_longitude,
            name      = COALESCE(NEW.customer_name, name)
        WHERE linked_order_id = NEW.id;
    END IF;

    RETURN NEW;
END;$$;


ALTER FUNCTION public.sync_customer_on_order_update() OWNER TO postgres;

--
-- Name: trigger_notify_handoff(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trigger_notify_handoff() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$declare
  v_secret    text;
  -- Project URL is not a secret, just project-specific config. If you
  -- migrate the project, edit this string here. Keeping it inline (rather
  -- than as a GUC) means there's no settings layer that can become stale.
  v_url       text := 'https://cmfliziflrbvoptfzhag.supabase.co/functions/v1/notify_handoff';
  v_body      jsonb;
  v_body_text text;
  v_ts        text;
  v_nonce     text;
  v_signature text;
begin
  -- Read HMAC key from Vault. Function runs SECURITY DEFINER (as the role
  -- that owns the function — typically postgres), which can read
  -- vault.decrypted_secrets; the authenticated and anon roles cannot.
  select decrypted_secret into v_secret
    from vault.decrypted_secrets
    where name = 'webhook_signing_secret'
    limit 1;

  if v_secret is null then
    -- Fail loud: an unsigned trigger is silently broken otherwise (the
    -- INSERT would succeed but no operators would be notified). Better
    -- to make the missing-config state obvious.
    raise exception 'webhook_signing_secret not configured in Vault';
  end if;

  v_body := jsonb_build_object('record', to_jsonb(NEW));
  -- pg_net serialises a jsonb body to its canonical text form for the wire,
  -- which equals body::text. We sign the same representation so the
  -- receiver can reconstruct the signing string from req.text().
  v_body_text := v_body::text;
  v_ts        := extract(epoch from now())::bigint::text;
  v_nonce     := gen_random_uuid()::text;

  v_signature := encode(
    extensions.hmac(
      v_ts || '.' || v_nonce || '.' || v_body_text,
      v_secret,
      'sha256'
    ),
    'hex'
  );

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
      'Content-Type',         'application/json',
      'X-Webhook-Timestamp',  v_ts,
      'X-Webhook-Nonce',      v_nonce,
      'X-Webhook-Signature',  'v1=' || v_signature
    ),
    body    := v_body
  );

  return NEW;
end;$$;


ALTER FUNCTION public.trigger_notify_handoff() OWNER TO postgres;

--
-- Name: update_slot_on_order_delete(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_slot_on_order_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_pizza_capacity DECIMAL(10,2);
    v_product_capacity DECIMAL(10,2);
BEGIN
    -- Only proceed if order has a slot
    IF OLD.slot_id IS NOT NULL THEN
        -- Calculate total pizza capacity to remove
        SELECT COALESCE(SUM(op.quantity * COALESCE(ps.capacity_multiplier, 1)), 0)
        INTO v_pizza_capacity
        FROM order_pizzas op
        JOIN pizzeria_products pp ON op.pizzeria_product_id = pp.id
        LEFT JOIN pizza_sizes ps ON pp.size_id = ps.id
        WHERE op.order_id = OLD.id;
        
        -- Calculate total product capacity to remove
        SELECT COALESCE(SUM(
            CASE WHEN pp.requires_slot = true THEN orp.quantity * 1.0 ELSE 0 END
        ), 0)
        INTO v_product_capacity
        FROM order_products orp
        JOIN pizzeria_products pp ON orp.pizzeria_product_id = pp.id
        WHERE orp.order_id = OLD.id;
        
        -- Update slot capacity
        UPDATE slot_availability
        SET used_capacity = GREATEST(used_capacity - v_pizza_capacity - v_product_capacity, 0)
        WHERE id = OLD.slot_id;
        
        RAISE NOTICE 'Order DELETE: Removed % capacity from slot %', 
            (v_pizza_capacity + v_product_capacity), OLD.slot_id;
    END IF;
    
    RETURN OLD;
END;
$$;


ALTER FUNCTION public.update_slot_on_order_delete() OWNER TO postgres;

--
-- Name: update_slot_on_order_slot_change(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_slot_on_order_slot_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_capacity DECIMAL(10,2) := 0;
BEGIN
    -- Solo se lo slot è cambiato
    IF OLD.slot_id IS DISTINCT FROM NEW.slot_id THEN

        -- Calcola la capacità delle pizze attuali dell'ordine
        SELECT COALESCE(SUM(op.quantity * ps.capacity_multiplier), 0)
        INTO v_capacity
        FROM order_pizzas op
        JOIN pizzeria_products pp ON op.pizzeria_product_id = pp.id
        JOIN pizza_sizes ps ON pp.size_id = ps.id
        WHERE op.order_id = NEW.id;

        -- Decrementa il vecchio slot
        IF OLD.slot_id IS NOT NULL THEN
            UPDATE slot_availability
            SET used_capacity = GREATEST(0, used_capacity - v_capacity)
            WHERE id = OLD.slot_id;
        END IF;

        -- Incrementa il nuovo slot
        IF NEW.slot_id IS NOT NULL THEN
            UPDATE slot_availability
            SET used_capacity = used_capacity + v_capacity
            WHERE id = NEW.slot_id;
        END IF;

    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_slot_on_order_slot_change() OWNER TO postgres;

--
-- Name: update_slot_on_pizza_delete(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_slot_on_pizza_delete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
    v_slot_id INTEGER;
    v_capacity_change DECIMAL(10,2);
BEGIN
    -- Get the slot_id from the parent order
    SELECT slot_id INTO v_slot_id
    FROM orders
    WHERE id = OLD.order_id;

    IF v_slot_id IS NOT NULL THEN
        -- Calculate capacity to remove
        SELECT OLD.quantity * COALESCE(ps.capacity_multiplier, 1)
        INTO v_capacity_change
        FROM pizzeria_products pp
        LEFT JOIN pizza_sizes ps ON pp.size_id = ps.id
        WHERE pp.id = OLD.pizzeria_product_id;

        -- Update slot capacity
        UPDATE slot_availability
        SET used_capacity = GREATEST(used_capacity - COALESCE(v_capacity_change, 0), 0)
        WHERE id = v_slot_id;

        RAISE NOTICE 'Pizza DELETE: Removed % capacity from slot %', v_capacity_change, v_slot_id;
    END IF;

    RETURN OLD;
END;$$;


ALTER FUNCTION public.update_slot_on_pizza_delete() OWNER TO postgres;

--
-- Name: update_slot_on_pizza_insert(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_slot_on_pizza_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
    v_slot_id INTEGER;
    v_capacity_change DECIMAL(10,2);
    v_current_capacity DECIMAL(10,2);
    v_max_capacity DECIMAL(10,2);
BEGIN
    -- Get the slot_id from the parent order
    SELECT slot_id INTO v_slot_id
    FROM orders
    WHERE id = NEW.order_id;

    -- Only update if order has a slot assigned
    IF v_slot_id IS NOT NULL THEN
        -- Calculate capacity: quantity * size multiplier
        SELECT NEW.quantity * COALESCE(ps.capacity_multiplier, 1)
        INTO v_capacity_change
        FROM pizzeria_products pp
        LEFT JOIN pizza_sizes ps ON pp.size_id = ps.id
        WHERE pp.id = NEW.pizzeria_product_id;

        -- Get current and max capacity
        SELECT used_capacity, total_capacity 
        INTO v_current_capacity, v_max_capacity
        FROM slot_availability
        WHERE id = v_slot_id;

        -- Check BEFORE updating
        -- IF (v_current_capacity + COALESCE(v_capacity_change, 0)) > v_max_capacity THEN
        --     RAISE EXCEPTION 'SLOT_FULL: Slot % is full (current: %, max: %, requested: %, the slot has just been filled)', 
        --         v_slot_id, v_current_capacity, v_max_capacity, v_capacity_change;
        -- END IF;

        -- Update slot capacity
        UPDATE slot_availability
        SET used_capacity = used_capacity + COALESCE(v_capacity_change, 0)
        WHERE id = v_slot_id;

        RAISE NOTICE 'Pizza INSERT: Added % capacity to slot %', v_capacity_change, v_slot_id;
    END IF;

    RETURN NEW;
END;$$;


ALTER FUNCTION public.update_slot_on_pizza_insert() OWNER TO postgres;

--
-- Name: update_slot_on_pizza_update(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_slot_on_pizza_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
    v_slot_id INTEGER;
    v_old_capacity DECIMAL(10,2);
    v_new_capacity DECIMAL(10,2);
    v_current_capacity DECIMAL(10,2);
    v_max_capacity DECIMAL(10,2);
    v_net_change DECIMAL(10,2);
BEGIN
    -- Get the slot_id from the parent order
    SELECT slot_id INTO v_slot_id
    FROM orders
    WHERE id = NEW.order_id;

    IF v_slot_id IS NOT NULL THEN
        -- Calculate OLD capacity
        SELECT OLD.quantity * COALESCE(ps.capacity_multiplier, 1)
        INTO v_old_capacity
        FROM pizzeria_products pp
        LEFT JOIN pizza_sizes ps ON pp.size_id = ps.id
        WHERE pp.id = OLD.pizzeria_product_id;

        -- Calculate NEW capacity
        SELECT NEW.quantity * COALESCE(ps.capacity_multiplier, 1)
        INTO v_new_capacity
        FROM pizzeria_products pp
        LEFT JOIN pizza_sizes ps ON pp.size_id = ps.id
        WHERE pp.id = NEW.pizzeria_product_id;

        -- Calculate net change
        v_net_change := COALESCE(v_new_capacity, 0) - COALESCE(v_old_capacity, 0);

        -- Only check if we're ADDING capacity (net_change > 0)
        IF v_net_change > 0 THEN
            -- Get current and max capacity
            SELECT used_capacity, total_capacity 
            INTO v_current_capacity, v_max_capacity
            FROM slot_availability
            WHERE id = v_slot_id;

            -- Check BEFORE updating
            -- IF (v_current_capacity + v_net_change) > v_max_capacity THEN
            --     RAISE EXCEPTION 'SLOT_FULL: Slot % is full (current: %, max: %, requested: %), slot has just been filled', 
            --         v_slot_id, v_current_capacity, v_max_capacity, v_net_change;
            -- END IF;
        END IF;

        -- Update slot capacity
        UPDATE slot_availability
        SET used_capacity = used_capacity - COALESCE(v_old_capacity, 0) + COALESCE(v_new_capacity, 0)
        WHERE id = v_slot_id;

        RAISE NOTICE 'Pizza UPDATE: Changed capacity by % on slot %', (v_new_capacity - v_old_capacity), v_slot_id;
    END IF;

    RETURN NEW;
END;$$;


ALTER FUNCTION public.update_slot_on_pizza_update() OWNER TO postgres;

--
-- Name: update_slot_on_product_delete(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_slot_on_product_delete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
    v_slot_id INTEGER;
    v_capacity_change DECIMAL(10,2);
BEGIN
    SELECT slot_id INTO v_slot_id FROM orders WHERE id = OLD.order_id;

    IF v_slot_id IS NOT NULL THEN
        -- Calculate capacity to remove based on requires_slot field
        SELECT CASE
            WHEN pp.requires_slot = true THEN OLD.quantity * 1.0
            ELSE 0
        END
        INTO v_capacity_change
        FROM pizzeria_products pp
        WHERE pp.id = OLD.pizzeria_product_id;

        UPDATE slot_availability
        SET used_capacity = GREATEST(used_capacity - COALESCE(v_capacity_change, 0), 0)
        WHERE id = v_slot_id;

        RAISE NOTICE 'Product DELETE: Removed % capacity from slot %', v_capacity_change, v_slot_id;
    END IF;

    RETURN OLD;
END;$$;


ALTER FUNCTION public.update_slot_on_product_delete() OWNER TO postgres;

--
-- Name: update_slot_on_product_insert(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_slot_on_product_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
    v_slot_id INTEGER;
    v_capacity_change DECIMAL(10,2);
BEGIN
    SELECT slot_id INTO v_slot_id FROM orders WHERE id = NEW.order_id;

    IF v_slot_id IS NOT NULL THEN
        -- Calculate capacity based on requires_slot field
        SELECT CASE
            WHEN pp.requires_slot = true THEN NEW.quantity * 1.0
            ELSE 0
        END
        INTO v_capacity_change
        FROM pizzeria_products pp
        WHERE pp.id = NEW.pizzeria_product_id;

        UPDATE slot_availability
        SET used_capacity = used_capacity + COALESCE(v_capacity_change, 0)
        WHERE id = v_slot_id;

        RAISE NOTICE 'Product INSERT: Added % capacity to slot %', v_capacity_change, v_slot_id;
    END IF;

    RETURN NEW;
END;$$;


ALTER FUNCTION public.update_slot_on_product_insert() OWNER TO postgres;

--
-- Name: update_slot_on_product_update(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_slot_on_product_update() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$DECLARE
    v_slot_id INTEGER;
    v_old_capacity DECIMAL(10,2);
    v_new_capacity DECIMAL(10,2);
BEGIN
    SELECT slot_id INTO v_slot_id FROM orders WHERE id = NEW.order_id;

    IF v_slot_id IS NOT NULL THEN
        -- Calculate OLD capacity based on requires_slot field
        SELECT CASE
            WHEN pp.requires_slot = true THEN OLD.quantity * 1.0
            ELSE 0
        END
        INTO v_old_capacity
        FROM pizzeria_products pp
        WHERE pp.id = OLD.pizzeria_product_id;

        -- Calculate NEW capacity based on requires_slot field
        SELECT CASE
            WHEN pp.requires_slot = true THEN NEW.quantity * 1.0
            ELSE 0
        END
        INTO v_new_capacity
        FROM pizzeria_products pp
        WHERE pp.id = NEW.pizzeria_product_id;

        UPDATE slot_availability
        SET used_capacity = used_capacity - COALESCE(v_old_capacity, 0) + COALESCE(v_new_capacity, 0)
        WHERE id = v_slot_id;

        RAISE NOTICE 'Product UPDATE: Changed capacity by % on slot %', (v_new_capacity - v_old_capacity), v_slot_id;
    END IF;

    RETURN NEW;
END;$$;


ALTER FUNCTION public.update_slot_on_product_update() OWNER TO postgres;

--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$BEGIN
    -- Convert the current time to Rome time before saving
    NEW.updated_at = (now() AT TIME ZONE 'Europe/Rome');
    RETURN NEW;
END;$$;


ALTER FUNCTION public.update_updated_at_column() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: customers; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.customers (
    id integer NOT NULL,
    pizzeria_id integer NOT NULL,
    phone character varying(20) NOT NULL,
    name character varying(255),
    address text,
    latitude double precision,
    longitude double precision,
    created_at timestamp without time zone DEFAULT now(),
    linked_order_id integer
);


ALTER TABLE public.customers OWNER TO postgres;

--
-- Name: customers_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.customers_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customers_id_seq OWNER TO postgres;

--
-- Name: customers_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.customers_id_seq OWNED BY public.customers.id;


--
-- Name: device_registrations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.device_registrations (
    id integer NOT NULL,
    device_id character varying(100) NOT NULL,
    pizzeria_id integer NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    last_seen timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    app_version character varying(20),
    device_model character varying(100),
    android_version character varying(10),
    notes text
);


ALTER TABLE public.device_registrations OWNER TO postgres;

--
-- Name: device_registrations_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.device_registrations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.device_registrations_id_seq OWNER TO postgres;

--
-- Name: device_registrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.device_registrations_id_seq OWNED BY public.device_registrations.id;


--
-- Name: handoff_requests; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.handoff_requests (
    id bigint NOT NULL,
    pizzeria_id integer NOT NULL,
    room_name text NOT NULL,
    caller_number text NOT NULL,
    partial_order_id integer,
    status text DEFAULT 'pending'::text NOT NULL,
    claimed_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    claimed_at timestamp with time zone,
    completed_at timestamp with time zone,
    rejected_by uuid,
    rejected_at timestamp with time zone,
    CONSTRAINT handoff_status_valid CHECK ((status = ANY (ARRAY['pending'::text, 'claimed'::text, 'in_progress'::text, 'timeout'::text, 'caller_abandoned'::text, 'completed'::text, 'completed_by_agent_resume'::text, 'rejected'::text])))
);


ALTER TABLE public.handoff_requests OWNER TO postgres;

--
-- Name: handoff_requests_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.handoff_requests_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.handoff_requests_id_seq OWNER TO postgres;

--
-- Name: handoff_requests_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.handoff_requests_id_seq OWNED BY public.handoff_requests.id;


--
-- Name: order_pizzas; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.order_pizzas (
    id integer NOT NULL,
    order_id integer,
    pizzeria_product_id integer,
    quantity integer DEFAULT 1,
    unit_price numeric(10,2) NOT NULL,
    customization_price numeric(10,2) DEFAULT 0,
    total_price numeric(10,2) NOT NULL,
    notes text
);


ALTER TABLE public.order_pizzas OWNER TO postgres;

--
-- Name: order_pizzas_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.order_pizzas_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.order_pizzas_id_seq OWNER TO postgres;

--
-- Name: order_pizzas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.order_pizzas_id_seq OWNED BY public.order_pizzas.id;


--
-- Name: order_products; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.order_products (
    id integer NOT NULL,
    order_id integer,
    pizzeria_product_id integer,
    quantity integer DEFAULT 1,
    unit_price numeric(10,2) NOT NULL,
    total_price numeric(10,2) NOT NULL
);


ALTER TABLE public.order_products OWNER TO postgres;

--
-- Name: order_products_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.order_products_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.order_products_id_seq OWNER TO postgres;

--
-- Name: order_products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.order_products_id_seq OWNED BY public.order_products.id;


--
-- Name: orders; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.orders (
    id integer NOT NULL,
    pizzeria_id integer,
    slot_id integer,
    customer_name character varying(255),
    customer_phone character varying(20),
    customer_address text,
    order_type character varying(20),
    payment_method character varying(50),
    total numeric(10,2) DEFAULT 0,
    notes text,
    completed boolean DEFAULT false,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    printed boolean DEFAULT false,
    customer_latitude double precision,
    customer_longitude double precision,
    rider_id smallint,
    is_partial boolean DEFAULT false NOT NULL,
    partial_reason character varying,
    transcript jsonb,
    needs_review boolean DEFAULT false NOT NULL,
    review_reasons jsonb,
    review_severity character varying,
    fiscal_receipt_number text,
    fiscal_compliance_url text,
    fiscal_receipt_at timestamp with time zone,
    CONSTRAINT orders_order_type_check CHECK (((order_type)::text = ANY ((ARRAY['pickup'::character varying, 'delivery'::character varying])::text[]))),
    CONSTRAINT orders_partial_reason_check CHECK ((((partial_reason)::text = ANY ((ARRAY['handoff'::character varying, 'disconnect'::character varying])::text[])) OR (partial_reason IS NULL))),
    CONSTRAINT orders_review_severity_check CHECK ((((review_severity)::text = ANY ((ARRAY['low'::character varying, 'medium'::character varying, 'high'::character varying])::text[])) OR (review_severity IS NULL)))
);


ALTER TABLE public.orders OWNER TO postgres;

--
-- Name: TABLE orders; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.orders IS 'Orders received from customers, linked to slots';


--
-- Name: COLUMN orders.customer_latitude; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.orders.customer_latitude IS 'latitude of the address';


--
-- Name: COLUMN orders.customer_longitude; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.orders.customer_longitude IS 'longitude of the customer address';


--
-- Name: COLUMN orders.rider_id; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.orders.rider_id IS 'rider id';


--
-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.orders_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.orders_id_seq OWNER TO postgres;

--
-- Name: orders_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.orders_id_seq OWNED BY public.orders.id;


--
-- Name: pizza_customizations; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.pizza_customizations (
    id integer NOT NULL,
    order_pizza_id integer,
    pizzeria_ingredient_id integer,
    action character varying(20),
    price_change numeric(10,2) DEFAULT 0,
    CONSTRAINT pizza_customizations_action_check CHECK (((action)::text = ANY (ARRAY[('add'::character varying)::text, ('remove'::character varying)::text, ('light'::character varying)::text, ('extra'::character varying)::text])))
);


ALTER TABLE public.pizza_customizations OWNER TO postgres;

--
-- Name: pizza_customizations_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.pizza_customizations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.pizza_customizations_id_seq OWNER TO postgres;

--
-- Name: pizza_customizations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.pizza_customizations_id_seq OWNED BY public.pizza_customizations.id;


--
-- Name: pizza_ingredients; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.pizza_ingredients (
    id integer NOT NULL,
    pizzeria_product_id integer,
    pizzeria_ingredient_id integer
);


ALTER TABLE public.pizza_ingredients OWNER TO postgres;

--
-- Name: pizza_ingredients_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.pizza_ingredients_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.pizza_ingredients_id_seq OWNER TO postgres;

--
-- Name: pizza_ingredients_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.pizza_ingredients_id_seq OWNED BY public.pizza_ingredients.id;


--
-- Name: pizza_sizes; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.pizza_sizes (
    id integer NOT NULL,
    name character varying(50) NOT NULL,
    capacity_multiplier numeric(3,2) NOT NULL,
    sort_order integer DEFAULT 0
);


ALTER TABLE public.pizza_sizes OWNER TO postgres;

--
-- Name: pizza_sizes_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.pizza_sizes_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.pizza_sizes_id_seq OWNER TO postgres;

--
-- Name: pizza_sizes_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.pizza_sizes_id_seq OWNED BY public.pizza_sizes.id;


--
-- Name: pizzeria_admins; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.pizzeria_admins (
    id bigint NOT NULL,
    user_id uuid NOT NULL,
    pizzeria_id integer NOT NULL,
    role text DEFAULT 'owner'::text,
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    name text
);


ALTER TABLE public.pizzeria_admins OWNER TO postgres;

--
-- Name: pizzeria_admins_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.pizzeria_admins ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.pizzeria_admins_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: pizzeria_fiskaly_config; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.pizzeria_fiskaly_config (
    pizzeria_id integer NOT NULL,
    fiskaly_subject_api_key text NOT NULL,
    fiskaly_subject_api_secret text NOT NULL,
    fiskaly_organization_id text NOT NULL,
    fiskaly_taxpayer_id text NOT NULL,
    fiskaly_location_id text NOT NULL,
    fiskaly_system_id text NOT NULL,
    fiskaly_bearer_token text,
    fiskaly_token_expires_at timestamp with time zone,
    pizzeria_vat_number text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.pizzeria_fiskaly_config OWNER TO postgres;

--
-- Name: pizzeria_ingredients; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.pizzeria_ingredients (
    id integer NOT NULL,
    pizzeria_id integer,
    name character varying(100) NOT NULL,
    allergens text,
    extra_price numeric(10,2) DEFAULT 0,
    available boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone
);


ALTER TABLE public.pizzeria_ingredients OWNER TO postgres;

--
-- Name: TABLE pizzeria_ingredients; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.pizzeria_ingredients IS 'Catalog of ingredients specific to each pizzeria';


--
-- Name: pizzeria_ingredients_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.pizzeria_ingredients_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.pizzeria_ingredients_id_seq OWNER TO postgres;

--
-- Name: pizzeria_ingredients_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.pizzeria_ingredients_id_seq OWNED BY public.pizzeria_ingredients.id;


--
-- Name: pizzeria_products; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.pizzeria_products (
    id integer NOT NULL,
    pizzeria_id integer,
    name character varying(255) NOT NULL,
    category character varying(100),
    size_id integer,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    price numeric(10,2) NOT NULL,
    requires_slot boolean DEFAULT false,
    customizable boolean DEFAULT false,
    available boolean DEFAULT true,
    subcategory character varying,
    compact_name text,
    subcategory_display text,
    CONSTRAINT pizzeria_products_category_check CHECK (((category)::text = ANY ((ARRAY['Pizze'::character varying, 'Bibite'::character varying, 'Dolci'::character varying, 'Antipasti'::character varying, 'Altro'::character varying])::text[]))),
    CONSTRAINT pizzeria_products_check CHECK (((requires_slot = false) OR ((category)::text = 'Pizze'::text))),
    CONSTRAINT pizzeria_products_check1 CHECK (((customizable = false) OR ((category)::text = 'Pizze'::text)))
);


ALTER TABLE public.pizzeria_products OWNER TO postgres;

--
-- Name: TABLE pizzeria_products; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.pizzeria_products IS 'Catalog of products specific to each pizzeria';


--
-- Name: COLUMN pizzeria_products.subcategory; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzeria_products.subcategory IS 'sottocategoria per associazione a scontrino';


--
-- Name: COLUMN pizzeria_products.compact_name; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzeria_products.compact_name IS 'Abbreviazione di name';


--
-- Name: COLUMN pizzeria_products.subcategory_display; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzeria_products.subcategory_display IS 'stottocategorie per la visualizzazione da gestionale';


--
-- Name: pizzeria_products_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.pizzeria_products_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.pizzeria_products_id_seq OWNER TO postgres;

--
-- Name: pizzeria_products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.pizzeria_products_id_seq OWNED BY public.pizzeria_products.id;


--
-- Name: pizzerias; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.pizzerias (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    address text,
    phone character varying(20),
    email character varying(255),
    default_slot_capacity integer DEFAULT 10,
    active boolean DEFAULT true,
    created_at timestamp with time zone,
    updated_at timestamp with time zone,
    latitude double precision NOT NULL,
    longitude double precision NOT NULL,
    delivery_radius_km double precision NOT NULL,
    sip_trunk_number character varying(50),
    delivery_area_geojson text,
    transfer_number character varying,
    premium_subscription boolean DEFAULT false NOT NULL,
    "API_key_print" text,
    "Printer_id" text,
    card_payment_delivery boolean DEFAULT false NOT NULL,
    available_riders smallint,
    avg_delivery_seconds integer,
    rider_max_capacity smallint,
    proximity_additional_delivery smallint,
    max_proximity_slots smallint,
    custom_instructions text,
    test_source_pizzeria_id integer,
    pizza_capacity smallint,
    max_trip_minutes double precision,
    early_tolerance_minutes double precision,
    late_tolerance_minutes double precision,
    detour_factor double precision,
    avg_speed_kmh double precision,
    stop_time_minutes double precision,
    new_trip_penalty double precision,
    delivery_payment_type text,
    delivery_extra_price real,
    delivery_extra_price_limit_low smallint,
    delivery_extra_price_limit_high text,
    max_deliveries_per_trip smallint,
    dist_tolerance_factor real,
    deviation_weight real,
    chupachups_threshold real,
    chupachups_radius real,
    chupachups_stem real,
    add_remove_logic text,
    stt_terms jsonb,
    ui_settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT chk_add_remove_logic CHECK ((add_remove_logic = ANY (ARRAY['type_one'::text, 'type_two'::text, 'type_three'::text]))),
    CONSTRAINT pizzerias_delivery_payment_type_check CHECK ((delivery_payment_type = ANY (ARRAY['type_one'::text, 'type_two'::text, 'type_three'::text, 'type_four'::text])))
);


ALTER TABLE public.pizzerias OWNER TO postgres;

--
-- Name: TABLE pizzerias; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.pizzerias IS 'Main table for multi-pizzeria management';


--
-- Name: COLUMN pizzerias.delivery_area_geojson; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.delivery_area_geojson IS 'geojson file that represent delivery area';


--
-- Name: COLUMN pizzerias.transfer_number; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.transfer_number IS 'Fallback number to talk with the pizzeria';


--
-- Name: COLUMN pizzerias.premium_subscription; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.premium_subscription IS 'Users with a premium subscription will be flagged as True';


--
-- Name: COLUMN pizzerias."API_key_print"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias."API_key_print" IS 'api of printnode';


--
-- Name: COLUMN pizzerias."Printer_id"; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias."Printer_id" IS 'Url of PrintNode';


--
-- Name: COLUMN pizzerias.card_payment_delivery; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.card_payment_delivery IS 'Vero se la pizzeria accetta pagamenti con carta anche a consegna';


--
-- Name: COLUMN pizzerias.available_riders; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.available_riders IS 'number of available riders';


--
-- Name: COLUMN pizzerias.avg_delivery_seconds; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.avg_delivery_seconds IS 'Average time in seconds for a delivery';


--
-- Name: COLUMN pizzerias.rider_max_capacity; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.rider_max_capacity IS 'Max number of delivery a rader can take in a run';


--
-- Name: COLUMN pizzerias.proximity_additional_delivery; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.proximity_additional_delivery IS 'meters of proximity which allows for a double delivey in the same trip';


--
-- Name: COLUMN pizzerias.max_proximity_slots; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.max_proximity_slots IS 'max even for proximity';


--
-- Name: COLUMN pizzerias.custom_instructions; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.custom_instructions IS 'Istruzioni custom per promo etc (vanno sul system)';


--
-- Name: COLUMN pizzerias.delivery_payment_type; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.delivery_payment_type IS 'Extra payment type two (fixed), Extra payment type three (variable with limit above),  Extra payment type one (variable).  type four (variable with minmum limit)';


--
-- Name: COLUMN pizzerias.delivery_extra_price; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.delivery_extra_price IS 'prezzo da aggiungere o moltiplicare';


--
-- Name: COLUMN pizzerias.delivery_extra_price_limit_low; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.delivery_extra_price_limit_low IS 'Limite prezzo minimo';


--
-- Name: COLUMN pizzerias.delivery_extra_price_limit_high; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.delivery_extra_price_limit_high IS 'Limite di prezzo massimo';


--
-- Name: COLUMN pizzerias.add_remove_logic; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.pizzerias.add_remove_logic IS 'logica su come funziona prezzo: tipo uno solo add, tipo due add remove, tipo tre add e sostituzione';


--
-- Name: pizzerias_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.pizzerias_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.pizzerias_id_seq OWNER TO postgres;

--
-- Name: pizzerias_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.pizzerias_id_seq OWNED BY public.pizzerias.id;


--
-- Name: slot_availability; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.slot_availability (
    id integer NOT NULL,
    pizzeria_id integer,
    date date NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    total_capacity integer NOT NULL,
    used_capacity numeric(10,2) DEFAULT 0,
    enabled boolean DEFAULT true NOT NULL
);


ALTER TABLE public.slot_availability OWNER TO postgres;

--
-- Name: TABLE slot_availability; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON TABLE public.slot_availability IS 'Time slots with capacity in pizza units';


--
-- Name: COLUMN slot_availability.used_capacity; Type: COMMENT; Schema: public; Owner: postgres
--

COMMENT ON COLUMN public.slot_availability.used_capacity IS 'Capacity used in pizza units (decimal to handle different sizes)';


--
-- Name: slot_availability_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.slot_availability_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.slot_availability_id_seq OWNER TO postgres;

--
-- Name: slot_availability_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.slot_availability_id_seq OWNED BY public.slot_availability.id;


--
-- Name: slot_config; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.slot_config (
    id integer NOT NULL,
    pizzeria_id integer,
    weekday integer,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    pizza_capacity integer,
    active boolean DEFAULT true,
    CONSTRAINT slot_config_weekday_check CHECK (((weekday >= 0) AND (weekday <= 6)))
);


ALTER TABLE public.slot_config OWNER TO postgres;

--
-- Name: slot_config_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.slot_config_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.slot_config_id_seq OWNER TO postgres;

--
-- Name: slot_config_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.slot_config_id_seq OWNED BY public.slot_config.id;


--
-- Name: v_available_slots; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_available_slots WITH (security_invoker='true') AS
 SELECT s.id,
    s.pizzeria_id,
    p.name AS pizzeria_name,
    s.date,
    s.start_time,
    s.end_time,
    s.total_capacity,
    s.used_capacity,
    ((s.total_capacity)::numeric - s.used_capacity) AS remaining_capacity
   FROM (public.slot_availability s
     JOIN public.pizzerias p ON ((s.pizzeria_id = p.id)))
  WHERE ((s.date >= CURRENT_DATE) AND (s.used_capacity < (s.total_capacity)::numeric));


ALTER VIEW public.v_available_slots OWNER TO postgres;

--
-- Name: v_pizzeria_menu; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_pizzeria_menu WITH (security_invoker='true') AS
 SELECT pr.pizzeria_id,
    pr.id AS pizzeria_product_id,
    pr.name AS product_name,
    pr.category,
    ps.name AS size,
    pr.price,
    pr.available,
    pr.customizable
   FROM (public.pizzeria_products pr
     LEFT JOIN public.pizza_sizes ps ON ((pr.size_id = ps.id)))
  WHERE (pr.available = true);


ALTER VIEW public.v_pizzeria_menu OWNER TO postgres;

--
-- Name: customers id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers ALTER COLUMN id SET DEFAULT nextval('public.customers_id_seq'::regclass);


--
-- Name: device_registrations id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_registrations ALTER COLUMN id SET DEFAULT nextval('public.device_registrations_id_seq'::regclass);


--
-- Name: handoff_requests id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.handoff_requests ALTER COLUMN id SET DEFAULT nextval('public.handoff_requests_id_seq'::regclass);


--
-- Name: order_pizzas id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_pizzas ALTER COLUMN id SET DEFAULT nextval('public.order_pizzas_id_seq'::regclass);


--
-- Name: order_products id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_products ALTER COLUMN id SET DEFAULT nextval('public.order_products_id_seq'::regclass);


--
-- Name: orders id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders ALTER COLUMN id SET DEFAULT nextval('public.orders_id_seq'::regclass);


--
-- Name: pizza_customizations id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizza_customizations ALTER COLUMN id SET DEFAULT nextval('public.pizza_customizations_id_seq'::regclass);


--
-- Name: pizza_ingredients id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizza_ingredients ALTER COLUMN id SET DEFAULT nextval('public.pizza_ingredients_id_seq'::regclass);


--
-- Name: pizza_sizes id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizza_sizes ALTER COLUMN id SET DEFAULT nextval('public.pizza_sizes_id_seq'::regclass);


--
-- Name: pizzeria_ingredients id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_ingredients ALTER COLUMN id SET DEFAULT nextval('public.pizzeria_ingredients_id_seq'::regclass);


--
-- Name: pizzeria_products id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_products ALTER COLUMN id SET DEFAULT nextval('public.pizzeria_products_id_seq'::regclass);


--
-- Name: pizzerias id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzerias ALTER COLUMN id SET DEFAULT nextval('public.pizzerias_id_seq'::regclass);


--
-- Name: slot_availability id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.slot_availability ALTER COLUMN id SET DEFAULT nextval('public.slot_availability_id_seq'::regclass);


--
-- Name: slot_config id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.slot_config ALTER COLUMN id SET DEFAULT nextval('public.slot_config_id_seq'::regclass);


--
-- Name: customers customers_pizzeria_id_phone_address_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pizzeria_id_phone_address_key UNIQUE (pizzeria_id, phone, address);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: device_registrations device_registrations_device_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_registrations
    ADD CONSTRAINT device_registrations_device_id_key UNIQUE (device_id);


--
-- Name: device_registrations device_registrations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_registrations
    ADD CONSTRAINT device_registrations_pkey PRIMARY KEY (id);


--
-- Name: handoff_requests handoff_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.handoff_requests
    ADD CONSTRAINT handoff_requests_pkey PRIMARY KEY (id);


--
-- Name: order_pizzas order_pizzas_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_pizzas
    ADD CONSTRAINT order_pizzas_pkey PRIMARY KEY (id);


--
-- Name: order_products order_products_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_products
    ADD CONSTRAINT order_products_pkey PRIMARY KEY (id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: pizza_customizations pizza_customizations_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizza_customizations
    ADD CONSTRAINT pizza_customizations_pkey PRIMARY KEY (id);


--
-- Name: pizza_ingredients pizza_ingredients_pizzeria_product_id_pizzeria_ingredient_i_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizza_ingredients
    ADD CONSTRAINT pizza_ingredients_pizzeria_product_id_pizzeria_ingredient_i_key UNIQUE (pizzeria_product_id, pizzeria_ingredient_id);


--
-- Name: pizza_ingredients pizza_ingredients_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizza_ingredients
    ADD CONSTRAINT pizza_ingredients_pkey PRIMARY KEY (id);


--
-- Name: pizza_sizes pizza_sizes_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizza_sizes
    ADD CONSTRAINT pizza_sizes_name_key UNIQUE (name);


--
-- Name: pizza_sizes pizza_sizes_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizza_sizes
    ADD CONSTRAINT pizza_sizes_pkey PRIMARY KEY (id);


--
-- Name: pizzeria_admins pizzeria_admins_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_admins
    ADD CONSTRAINT pizzeria_admins_pkey PRIMARY KEY (id);


--
-- Name: pizzeria_admins pizzeria_admins_user_id_pizzeria_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_admins
    ADD CONSTRAINT pizzeria_admins_user_id_pizzeria_id_key UNIQUE (user_id, pizzeria_id);


--
-- Name: pizzeria_fiskaly_config pizzeria_fiskaly_config_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_fiskaly_config
    ADD CONSTRAINT pizzeria_fiskaly_config_pkey PRIMARY KEY (pizzeria_id);


--
-- Name: pizzeria_ingredients pizzeria_ingredients_pizzeria_id_name_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_ingredients
    ADD CONSTRAINT pizzeria_ingredients_pizzeria_id_name_key UNIQUE (pizzeria_id, name);


--
-- Name: pizzeria_ingredients pizzeria_ingredients_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_ingredients
    ADD CONSTRAINT pizzeria_ingredients_pkey PRIMARY KEY (id);


--
-- Name: pizzeria_products pizzeria_products_pizzeria_id_name_size_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_products
    ADD CONSTRAINT pizzeria_products_pizzeria_id_name_size_id_key UNIQUE (pizzeria_id, name, size_id);


--
-- Name: pizzeria_products pizzeria_products_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_products
    ADD CONSTRAINT pizzeria_products_pkey PRIMARY KEY (id);


--
-- Name: pizzerias pizzerias_API_key_print_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzerias
    ADD CONSTRAINT "pizzerias_API_key_print_key" UNIQUE ("API_key_print");


--
-- Name: pizzerias pizzerias_PrintNode_url_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzerias
    ADD CONSTRAINT "pizzerias_PrintNode_url_key" UNIQUE ("Printer_id");


--
-- Name: pizzerias pizzerias_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzerias
    ADD CONSTRAINT pizzerias_pkey PRIMARY KEY (id);


--
-- Name: pizzerias pizzerias_transfer_number_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzerias
    ADD CONSTRAINT pizzerias_transfer_number_key UNIQUE (transfer_number);


--
-- Name: slot_availability slot_availability_pizzeria_id_date_start_time_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.slot_availability
    ADD CONSTRAINT slot_availability_pizzeria_id_date_start_time_key UNIQUE (pizzeria_id, date, start_time);


--
-- Name: slot_availability slot_availability_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.slot_availability
    ADD CONSTRAINT slot_availability_pkey PRIMARY KEY (id);


--
-- Name: slot_config slot_config_pizzeria_id_weekday_start_time_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.slot_config
    ADD CONSTRAINT slot_config_pizzeria_id_weekday_start_time_key UNIQUE (pizzeria_id, weekday, start_time);


--
-- Name: slot_config slot_config_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.slot_config
    ADD CONSTRAINT slot_config_pkey PRIMARY KEY (id);


--
-- Name: pizzerias unique_sip_trunk_number; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzerias
    ADD CONSTRAINT unique_sip_trunk_number UNIQUE (sip_trunk_number);


--
-- Name: idx_customers_linked_order_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_customers_linked_order_id ON public.customers USING btree (linked_order_id);


--
-- Name: idx_customizations_order_pizza_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_customizations_order_pizza_id ON public.pizza_customizations USING btree (order_pizza_id);


--
-- Name: idx_device_registrations_last_seen; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_device_registrations_last_seen ON public.device_registrations USING btree (last_seen) WHERE (is_active = true);


--
-- Name: idx_device_registrations_lookup; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_device_registrations_lookup ON public.device_registrations USING btree (device_id, pizzeria_id);


--
-- Name: idx_handoff_requests_active_by_operator; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_handoff_requests_active_by_operator ON public.handoff_requests USING btree (claimed_by) WHERE (status = ANY (ARRAY['claimed'::text, 'in_progress'::text]));


--
-- Name: idx_handoff_requests_pending; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_handoff_requests_pending ON public.handoff_requests USING btree (pizzeria_id, created_at) WHERE (status = 'pending'::text);


--
-- Name: idx_order_pizzas_order_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_order_pizzas_order_id ON public.order_pizzas USING btree (order_id);


--
-- Name: idx_order_products_order_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_order_products_order_id ON public.order_products USING btree (order_id);


--
-- Name: idx_orders_pizzeria_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_orders_pizzeria_id ON public.orders USING btree (pizzeria_id);


--
-- Name: idx_orders_slot; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_orders_slot ON public.orders USING btree (slot_id);


--
-- Name: idx_pizzeria_admins_user_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_pizzeria_admins_user_id ON public.pizzeria_admins USING btree (user_id);


--
-- Name: idx_pizzeria_ingredients_lookup; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_pizzeria_ingredients_lookup ON public.pizzeria_ingredients USING btree (pizzeria_id, available);


--
-- Name: idx_pizzeria_products_lookup; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_pizzeria_products_lookup ON public.pizzeria_products USING btree (pizzeria_id, category, available);


--
-- Name: idx_pizzeria_products_pizzeria_id; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_pizzeria_products_pizzeria_id ON public.pizzeria_products USING btree (pizzeria_id);


--
-- Name: idx_slot_availability_lookup; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_slot_availability_lookup ON public.slot_availability USING btree (pizzeria_id, date, used_capacity);


--
-- Name: handoff_requests on_handoff_request_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER on_handoff_request_insert AFTER INSERT ON public.handoff_requests FOR EACH ROW EXECUTE FUNCTION public.trigger_notify_handoff();


--
-- Name: pizzeria_ingredients set_pizzeria_ingredients_created_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_pizzeria_ingredients_created_at BEFORE INSERT ON public.pizzeria_ingredients FOR EACH ROW EXECUTE FUNCTION public.set_created_at_column();


--
-- Name: pizzeria_products set_pizzeria_products_created_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_pizzeria_products_created_at BEFORE INSERT ON public.pizzeria_products FOR EACH ROW EXECUTE FUNCTION public.set_created_at_column();


--
-- Name: pizzerias set_pizzerias_created_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_pizzerias_created_at BEFORE INSERT ON public.pizzerias FOR EACH ROW EXECUTE FUNCTION public.set_created_at_column();


--
-- Name: orders trg_populate_customer_on_order_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_populate_customer_on_order_insert AFTER INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.populate_customer_from_order();


--
-- Name: orders trg_sync_customer_on_order_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_sync_customer_on_order_update AFTER UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.sync_customer_on_order_update();


--
-- Name: orders trigger_update_slot_on_order_delete; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_update_slot_on_order_delete BEFORE DELETE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.update_slot_on_order_delete();


--
-- Name: orders trigger_update_slot_on_order_slot_change; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trigger_update_slot_on_order_slot_change AFTER UPDATE OF slot_id ON public.orders FOR EACH ROW EXECUTE FUNCTION public.update_slot_on_order_slot_change();


--
-- Name: orders update_orders_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_orders_updated_at BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: pizzeria_ingredients update_pizzeria_ingredients_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_pizzeria_ingredients_updated_at BEFORE UPDATE ON public.pizzeria_ingredients FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: pizzeria_products update_pizzeria_products_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_pizzeria_products_updated_at BEFORE UPDATE ON public.pizzeria_products FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: pizzerias update_pizzerias_updated_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_pizzerias_updated_at BEFORE UPDATE ON public.pizzerias FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: order_pizzas update_slot_on_pizza_delete; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_slot_on_pizza_delete AFTER DELETE ON public.order_pizzas FOR EACH ROW EXECUTE FUNCTION public.update_slot_on_pizza_delete();


--
-- Name: order_pizzas update_slot_on_pizza_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_slot_on_pizza_insert AFTER INSERT ON public.order_pizzas FOR EACH ROW EXECUTE FUNCTION public.update_slot_on_pizza_insert();


--
-- Name: order_pizzas update_slot_on_pizza_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_slot_on_pizza_update AFTER UPDATE ON public.order_pizzas FOR EACH ROW EXECUTE FUNCTION public.update_slot_on_pizza_update();


--
-- Name: order_products update_slot_on_product_delete; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_slot_on_product_delete AFTER DELETE ON public.order_products FOR EACH ROW EXECUTE FUNCTION public.update_slot_on_product_delete();


--
-- Name: order_products update_slot_on_product_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_slot_on_product_insert AFTER INSERT ON public.order_products FOR EACH ROW EXECUTE FUNCTION public.update_slot_on_product_insert();


--
-- Name: order_products update_slot_on_product_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER update_slot_on_product_update AFTER UPDATE ON public.order_products FOR EACH ROW EXECUTE FUNCTION public.update_slot_on_product_update();


--
-- Name: customers customers_linked_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_linked_order_id_fkey FOREIGN KEY (linked_order_id) REFERENCES public.orders(id) ON DELETE SET NULL;


--
-- Name: customers customers_pizzeria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pizzeria_id_fkey FOREIGN KEY (pizzeria_id) REFERENCES public.pizzerias(id) ON DELETE CASCADE;


--
-- Name: device_registrations device_registrations_pizzeria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.device_registrations
    ADD CONSTRAINT device_registrations_pizzeria_id_fkey FOREIGN KEY (pizzeria_id) REFERENCES public.pizzerias(id) ON DELETE CASCADE;


--
-- Name: handoff_requests handoff_requests_claimed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.handoff_requests
    ADD CONSTRAINT handoff_requests_claimed_by_fkey FOREIGN KEY (claimed_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: handoff_requests handoff_requests_partial_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.handoff_requests
    ADD CONSTRAINT handoff_requests_partial_order_id_fkey FOREIGN KEY (partial_order_id) REFERENCES public.orders(id) ON DELETE SET NULL;


--
-- Name: handoff_requests handoff_requests_pizzeria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.handoff_requests
    ADD CONSTRAINT handoff_requests_pizzeria_id_fkey FOREIGN KEY (pizzeria_id) REFERENCES public.pizzerias(id) ON DELETE CASCADE;


--
-- Name: handoff_requests handoff_requests_rejected_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.handoff_requests
    ADD CONSTRAINT handoff_requests_rejected_by_fkey FOREIGN KEY (rejected_by) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: order_pizzas order_pizzas_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_pizzas
    ADD CONSTRAINT order_pizzas_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: order_pizzas order_pizzas_pizzeria_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_pizzas
    ADD CONSTRAINT order_pizzas_pizzeria_product_id_fkey FOREIGN KEY (pizzeria_product_id) REFERENCES public.pizzeria_products(id);


--
-- Name: order_products order_products_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_products
    ADD CONSTRAINT order_products_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: order_products order_products_pizzeria_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_products
    ADD CONSTRAINT order_products_pizzeria_product_id_fkey FOREIGN KEY (pizzeria_product_id) REFERENCES public.pizzeria_products(id);


--
-- Name: orders orders_pizzeria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pizzeria_id_fkey FOREIGN KEY (pizzeria_id) REFERENCES public.pizzerias(id) ON DELETE CASCADE;


--
-- Name: orders orders_slot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES public.slot_availability(id);


--
-- Name: pizza_customizations pizza_customizations_order_pizza_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizza_customizations
    ADD CONSTRAINT pizza_customizations_order_pizza_id_fkey FOREIGN KEY (order_pizza_id) REFERENCES public.order_pizzas(id) ON DELETE CASCADE;


--
-- Name: pizza_customizations pizza_customizations_pizzeria_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizza_customizations
    ADD CONSTRAINT pizza_customizations_pizzeria_ingredient_id_fkey FOREIGN KEY (pizzeria_ingredient_id) REFERENCES public.pizzeria_ingredients(id);


--
-- Name: pizza_ingredients pizza_ingredients_pizzeria_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizza_ingredients
    ADD CONSTRAINT pizza_ingredients_pizzeria_ingredient_id_fkey FOREIGN KEY (pizzeria_ingredient_id) REFERENCES public.pizzeria_ingredients(id) ON DELETE CASCADE;


--
-- Name: pizza_ingredients pizza_ingredients_pizzeria_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizza_ingredients
    ADD CONSTRAINT pizza_ingredients_pizzeria_product_id_fkey FOREIGN KEY (pizzeria_product_id) REFERENCES public.pizzeria_products(id) ON DELETE CASCADE;


--
-- Name: pizzeria_admins pizzeria_admins_pizzeria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_admins
    ADD CONSTRAINT pizzeria_admins_pizzeria_id_fkey FOREIGN KEY (pizzeria_id) REFERENCES public.pizzerias(id) ON DELETE CASCADE;


--
-- Name: pizzeria_admins pizzeria_admins_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_admins
    ADD CONSTRAINT pizzeria_admins_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: pizzeria_fiskaly_config pizzeria_fiskaly_config_pizzeria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_fiskaly_config
    ADD CONSTRAINT pizzeria_fiskaly_config_pizzeria_id_fkey FOREIGN KEY (pizzeria_id) REFERENCES public.pizzerias(id) ON DELETE CASCADE;


--
-- Name: pizzeria_ingredients pizzeria_ingredients_pizzeria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_ingredients
    ADD CONSTRAINT pizzeria_ingredients_pizzeria_id_fkey FOREIGN KEY (pizzeria_id) REFERENCES public.pizzerias(id) ON DELETE CASCADE;


--
-- Name: pizzeria_products pizzeria_products_pizzeria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_products
    ADD CONSTRAINT pizzeria_products_pizzeria_id_fkey FOREIGN KEY (pizzeria_id) REFERENCES public.pizzerias(id) ON DELETE CASCADE;


--
-- Name: pizzeria_products pizzeria_products_size_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzeria_products
    ADD CONSTRAINT pizzeria_products_size_id_fkey FOREIGN KEY (size_id) REFERENCES public.pizza_sizes(id);


--
-- Name: pizzerias pizzerias_test_source_pizzeria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pizzerias
    ADD CONSTRAINT pizzerias_test_source_pizzeria_id_fkey FOREIGN KEY (test_source_pizzeria_id) REFERENCES public.pizzerias(id);


--
-- Name: slot_availability slot_availability_pizzeria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.slot_availability
    ADD CONSTRAINT slot_availability_pizzeria_id_fkey FOREIGN KEY (pizzeria_id) REFERENCES public.pizzerias(id) ON DELETE CASCADE;


--
-- Name: slot_config slot_config_pizzeria_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.slot_config
    ADD CONSTRAINT slot_config_pizzeria_id_fkey FOREIGN KEY (pizzeria_id) REFERENCES public.pizzerias(id) ON DELETE CASCADE;


--
-- Name: pizzeria_fiskaly_config Admins can read own fiskaly config; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Admins can read own fiskaly config" ON public.pizzeria_fiskaly_config FOR SELECT USING ((pizzeria_id IN ( SELECT pizzeria_admins.pizzeria_id
   FROM public.pizzeria_admins
  WHERE (pizzeria_admins.user_id = auth.uid()))));


--
-- Name: device_registrations Admins can view devices; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Admins can view devices" ON public.device_registrations FOR SELECT USING ((pizzeria_id IN ( SELECT pizzeria_admins.pizzeria_id
   FROM public.pizzeria_admins
  WHERE (pizzeria_admins.user_id = auth.uid()))));


--
-- Name: customers Admins has full access to own customers; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Admins has full access to own customers" ON public.customers USING ((pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids))) WITH CHECK ((pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids)));


--
-- Name: pizza_customizations Owner full access customizations; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Owner full access customizations" ON public.pizza_customizations USING ((order_pizza_id IN ( SELECT op.id
   FROM (public.order_pizzas op
     JOIN public.orders o ON ((o.id = op.order_id)))
  WHERE (o.pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids))))) WITH CHECK ((order_pizza_id IN ( SELECT op.id
   FROM (public.order_pizzas op
     JOIN public.orders o ON ((o.id = op.order_id)))
  WHERE (o.pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids)))));


--
-- Name: pizzeria_ingredients Owner full access ingredients; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Owner full access ingredients" ON public.pizzeria_ingredients USING ((pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids))) WITH CHECK ((pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids)));


--
-- Name: pizza_ingredients Owner full access join ingredients; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Owner full access join ingredients" ON public.pizza_ingredients USING ((pizzeria_product_id IN ( SELECT pizzeria_products.id
   FROM public.pizzeria_products
  WHERE (pizzeria_products.pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids))))) WITH CHECK ((pizzeria_product_id IN ( SELECT pizzeria_products.id
   FROM public.pizzeria_products
  WHERE (pizzeria_products.pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids)))));


--
-- Name: order_pizzas Owner full access order pizzas; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Owner full access order pizzas" ON public.order_pizzas USING ((order_id IN ( SELECT orders.id
   FROM public.orders
  WHERE (orders.pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids))))) WITH CHECK ((order_id IN ( SELECT orders.id
   FROM public.orders
  WHERE (orders.pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids)))));


--
-- Name: order_products Owner full access order products; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Owner full access order products" ON public.order_products USING ((order_id IN ( SELECT orders.id
   FROM public.orders
  WHERE (orders.pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids))))) WITH CHECK ((order_id IN ( SELECT orders.id
   FROM public.orders
  WHERE (orders.pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids)))));


--
-- Name: orders Owner full access orders; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Owner full access orders" ON public.orders USING ((pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids))) WITH CHECK ((pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids)));


--
-- Name: pizzeria_products Owner full access products; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Owner full access products" ON public.pizzeria_products USING ((pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids))) WITH CHECK ((pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids)));


--
-- Name: slot_config Owner full access slot config; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Owner full access slot config" ON public.slot_config USING ((pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids))) WITH CHECK ((pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids)));


--
-- Name: slot_availability Owner full access slots; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Owner full access slots" ON public.slot_availability USING ((pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids))) WITH CHECK ((pizzeria_id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids)));


--
-- Name: pizzerias Owner read pizzeria; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Owner read pizzeria" ON public.pizzerias FOR SELECT USING ((id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids)));


--
-- Name: pizzerias Owner update pizzeria; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Owner update pizzeria" ON public.pizzerias FOR UPDATE USING ((id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids))) WITH CHECK ((id IN ( SELECT public.get_my_pizzeria_ids() AS get_my_pizzeria_ids)));


--
-- Name: pizza_sizes Public read pizza sizes; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Public read pizza sizes" ON public.pizza_sizes FOR SELECT USING (true);


--
-- Name: pizzeria_admins Users read own admin record; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Users read own admin record" ON public.pizzeria_admins FOR SELECT USING ((user_id = auth.uid()));


--
-- Name: pizzeria_admins Users update own admin record; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "Users update own admin record" ON public.pizzeria_admins FOR UPDATE USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));


--
-- Name: customers; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

--
-- Name: device_registrations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.device_registrations ENABLE ROW LEVEL SECURITY;

--
-- Name: handoff_requests; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.handoff_requests ENABLE ROW LEVEL SECURITY;

--
-- Name: handoff_requests handoff_select_own; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY handoff_select_own ON public.handoff_requests FOR SELECT USING ((pizzeria_id IN ( SELECT get_my_pizzeria_ids.pizzeria_id
   FROM public.get_my_pizzeria_ids() get_my_pizzeria_ids(pizzeria_id))));


--
-- Name: order_pizzas; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.order_pizzas ENABLE ROW LEVEL SECURITY;

--
-- Name: order_products; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.order_products ENABLE ROW LEVEL SECURITY;

--
-- Name: orders; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;

--
-- Name: pizza_customizations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.pizza_customizations ENABLE ROW LEVEL SECURITY;

--
-- Name: pizza_ingredients; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.pizza_ingredients ENABLE ROW LEVEL SECURITY;

--
-- Name: pizza_sizes; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.pizza_sizes ENABLE ROW LEVEL SECURITY;

--
-- Name: pizzeria_admins; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.pizzeria_admins ENABLE ROW LEVEL SECURITY;

--
-- Name: pizzeria_fiskaly_config; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.pizzeria_fiskaly_config ENABLE ROW LEVEL SECURITY;

--
-- Name: pizzeria_ingredients; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.pizzeria_ingredients ENABLE ROW LEVEL SECURITY;

--
-- Name: pizzeria_products; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.pizzeria_products ENABLE ROW LEVEL SECURITY;

--
-- Name: pizzerias; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.pizzerias ENABLE ROW LEVEL SECURITY;

--
-- Name: slot_availability; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.slot_availability ENABLE ROW LEVEL SECURITY;

--
-- Name: slot_config; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE public.slot_config ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION clear_all_data(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.clear_all_data() TO anon;
GRANT ALL ON FUNCTION public.clear_all_data() TO authenticated;
GRANT ALL ON FUNCTION public.clear_all_data() TO service_role;


--
-- Name: FUNCTION generate_daily_slots(p_pizzeria_id integer, p_date date); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.generate_daily_slots(p_pizzeria_id integer, p_date date) TO anon;
GRANT ALL ON FUNCTION public.generate_daily_slots(p_pizzeria_id integer, p_date date) TO authenticated;
GRANT ALL ON FUNCTION public.generate_daily_slots(p_pizzeria_id integer, p_date date) TO service_role;


--
-- Name: FUNCTION generate_slots_for_days(p_pizzeria_id integer, p_days integer); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.generate_slots_for_days(p_pizzeria_id integer, p_days integer) TO anon;
GRANT ALL ON FUNCTION public.generate_slots_for_days(p_pizzeria_id integer, p_days integer) TO authenticated;
GRANT ALL ON FUNCTION public.generate_slots_for_days(p_pizzeria_id integer, p_days integer) TO service_role;


--
-- Name: FUNCTION generate_tomorrow_slots(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.generate_tomorrow_slots() TO anon;
GRANT ALL ON FUNCTION public.generate_tomorrow_slots() TO authenticated;
GRANT ALL ON FUNCTION public.generate_tomorrow_slots() TO service_role;


--
-- Name: FUNCTION get_my_pizzeria_ids(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.get_my_pizzeria_ids() TO anon;
GRANT ALL ON FUNCTION public.get_my_pizzeria_ids() TO authenticated;
GRANT ALL ON FUNCTION public.get_my_pizzeria_ids() TO service_role;


--
-- Name: FUNCTION is_operator_busy(p_user_id uuid); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.is_operator_busy(p_user_id uuid) TO anon;
GRANT ALL ON FUNCTION public.is_operator_busy(p_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.is_operator_busy(p_user_id uuid) TO service_role;


--
-- Name: FUNCTION populate_customer_from_order(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.populate_customer_from_order() TO anon;
GRANT ALL ON FUNCTION public.populate_customer_from_order() TO authenticated;
GRANT ALL ON FUNCTION public.populate_customer_from_order() TO service_role;


--
-- Name: FUNCTION recalculate_all_slot_capacities(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.recalculate_all_slot_capacities() TO anon;
GRANT ALL ON FUNCTION public.recalculate_all_slot_capacities() TO authenticated;
GRANT ALL ON FUNCTION public.recalculate_all_slot_capacities() TO service_role;


--
-- Name: FUNCTION set_created_at_column(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.set_created_at_column() TO anon;
GRANT ALL ON FUNCTION public.set_created_at_column() TO authenticated;
GRANT ALL ON FUNCTION public.set_created_at_column() TO service_role;


--
-- Name: FUNCTION sync_customer_on_order_update(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.sync_customer_on_order_update() TO anon;
GRANT ALL ON FUNCTION public.sync_customer_on_order_update() TO authenticated;
GRANT ALL ON FUNCTION public.sync_customer_on_order_update() TO service_role;


--
-- Name: FUNCTION trigger_notify_handoff(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.trigger_notify_handoff() FROM PUBLIC;
GRANT ALL ON FUNCTION public.trigger_notify_handoff() TO service_role;


--
-- Name: FUNCTION update_slot_on_order_delete(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.update_slot_on_order_delete() TO anon;
GRANT ALL ON FUNCTION public.update_slot_on_order_delete() TO authenticated;
GRANT ALL ON FUNCTION public.update_slot_on_order_delete() TO service_role;


--
-- Name: FUNCTION update_slot_on_order_slot_change(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.update_slot_on_order_slot_change() TO anon;
GRANT ALL ON FUNCTION public.update_slot_on_order_slot_change() TO authenticated;
GRANT ALL ON FUNCTION public.update_slot_on_order_slot_change() TO service_role;


--
-- Name: FUNCTION update_slot_on_pizza_delete(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.update_slot_on_pizza_delete() TO anon;
GRANT ALL ON FUNCTION public.update_slot_on_pizza_delete() TO authenticated;
GRANT ALL ON FUNCTION public.update_slot_on_pizza_delete() TO service_role;


--
-- Name: FUNCTION update_slot_on_pizza_insert(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.update_slot_on_pizza_insert() TO anon;
GRANT ALL ON FUNCTION public.update_slot_on_pizza_insert() TO authenticated;
GRANT ALL ON FUNCTION public.update_slot_on_pizza_insert() TO service_role;


--
-- Name: FUNCTION update_slot_on_pizza_update(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.update_slot_on_pizza_update() TO anon;
GRANT ALL ON FUNCTION public.update_slot_on_pizza_update() TO authenticated;
GRANT ALL ON FUNCTION public.update_slot_on_pizza_update() TO service_role;


--
-- Name: FUNCTION update_slot_on_product_delete(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.update_slot_on_product_delete() TO anon;
GRANT ALL ON FUNCTION public.update_slot_on_product_delete() TO authenticated;
GRANT ALL ON FUNCTION public.update_slot_on_product_delete() TO service_role;


--
-- Name: FUNCTION update_slot_on_product_insert(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.update_slot_on_product_insert() TO anon;
GRANT ALL ON FUNCTION public.update_slot_on_product_insert() TO authenticated;
GRANT ALL ON FUNCTION public.update_slot_on_product_insert() TO service_role;


--
-- Name: FUNCTION update_slot_on_product_update(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.update_slot_on_product_update() TO anon;
GRANT ALL ON FUNCTION public.update_slot_on_product_update() TO authenticated;
GRANT ALL ON FUNCTION public.update_slot_on_product_update() TO service_role;


--
-- Name: FUNCTION update_updated_at_column(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.update_updated_at_column() TO anon;
GRANT ALL ON FUNCTION public.update_updated_at_column() TO authenticated;
GRANT ALL ON FUNCTION public.update_updated_at_column() TO service_role;


--
-- Name: TABLE customers; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.customers TO anon;
GRANT ALL ON TABLE public.customers TO authenticated;
GRANT ALL ON TABLE public.customers TO service_role;


--
-- Name: SEQUENCE customers_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.customers_id_seq TO anon;
GRANT ALL ON SEQUENCE public.customers_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.customers_id_seq TO service_role;


--
-- Name: TABLE device_registrations; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.device_registrations TO anon;
GRANT ALL ON TABLE public.device_registrations TO authenticated;
GRANT ALL ON TABLE public.device_registrations TO service_role;


--
-- Name: SEQUENCE device_registrations_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.device_registrations_id_seq TO anon;
GRANT ALL ON SEQUENCE public.device_registrations_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.device_registrations_id_seq TO service_role;


--
-- Name: TABLE handoff_requests; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.handoff_requests TO anon;
GRANT ALL ON TABLE public.handoff_requests TO authenticated;
GRANT ALL ON TABLE public.handoff_requests TO service_role;


--
-- Name: SEQUENCE handoff_requests_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.handoff_requests_id_seq TO anon;
GRANT ALL ON SEQUENCE public.handoff_requests_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.handoff_requests_id_seq TO service_role;


--
-- Name: TABLE order_pizzas; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.order_pizzas TO anon;
GRANT ALL ON TABLE public.order_pizzas TO authenticated;
GRANT ALL ON TABLE public.order_pizzas TO service_role;


--
-- Name: SEQUENCE order_pizzas_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.order_pizzas_id_seq TO anon;
GRANT ALL ON SEQUENCE public.order_pizzas_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.order_pizzas_id_seq TO service_role;


--
-- Name: TABLE order_products; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.order_products TO anon;
GRANT ALL ON TABLE public.order_products TO authenticated;
GRANT ALL ON TABLE public.order_products TO service_role;


--
-- Name: SEQUENCE order_products_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.order_products_id_seq TO anon;
GRANT ALL ON SEQUENCE public.order_products_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.order_products_id_seq TO service_role;


--
-- Name: TABLE orders; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.orders TO anon;
GRANT ALL ON TABLE public.orders TO authenticated;
GRANT ALL ON TABLE public.orders TO service_role;


--
-- Name: SEQUENCE orders_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.orders_id_seq TO anon;
GRANT ALL ON SEQUENCE public.orders_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.orders_id_seq TO service_role;


--
-- Name: TABLE pizza_customizations; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.pizza_customizations TO anon;
GRANT ALL ON TABLE public.pizza_customizations TO authenticated;
GRANT ALL ON TABLE public.pizza_customizations TO service_role;


--
-- Name: SEQUENCE pizza_customizations_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.pizza_customizations_id_seq TO anon;
GRANT ALL ON SEQUENCE public.pizza_customizations_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.pizza_customizations_id_seq TO service_role;


--
-- Name: TABLE pizza_ingredients; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.pizza_ingredients TO anon;
GRANT ALL ON TABLE public.pizza_ingredients TO authenticated;
GRANT ALL ON TABLE public.pizza_ingredients TO service_role;


--
-- Name: SEQUENCE pizza_ingredients_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.pizza_ingredients_id_seq TO anon;
GRANT ALL ON SEQUENCE public.pizza_ingredients_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.pizza_ingredients_id_seq TO service_role;


--
-- Name: TABLE pizza_sizes; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.pizza_sizes TO anon;
GRANT ALL ON TABLE public.pizza_sizes TO authenticated;
GRANT ALL ON TABLE public.pizza_sizes TO service_role;


--
-- Name: SEQUENCE pizza_sizes_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.pizza_sizes_id_seq TO anon;
GRANT ALL ON SEQUENCE public.pizza_sizes_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.pizza_sizes_id_seq TO service_role;


--
-- Name: TABLE pizzeria_admins; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.pizzeria_admins TO anon;
GRANT ALL ON TABLE public.pizzeria_admins TO authenticated;
GRANT ALL ON TABLE public.pizzeria_admins TO service_role;


--
-- Name: SEQUENCE pizzeria_admins_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.pizzeria_admins_id_seq TO anon;
GRANT ALL ON SEQUENCE public.pizzeria_admins_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.pizzeria_admins_id_seq TO service_role;


--
-- Name: TABLE pizzeria_fiskaly_config; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.pizzeria_fiskaly_config TO anon;
GRANT ALL ON TABLE public.pizzeria_fiskaly_config TO authenticated;
GRANT ALL ON TABLE public.pizzeria_fiskaly_config TO service_role;


--
-- Name: TABLE pizzeria_ingredients; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.pizzeria_ingredients TO anon;
GRANT ALL ON TABLE public.pizzeria_ingredients TO authenticated;
GRANT ALL ON TABLE public.pizzeria_ingredients TO service_role;


--
-- Name: SEQUENCE pizzeria_ingredients_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.pizzeria_ingredients_id_seq TO anon;
GRANT ALL ON SEQUENCE public.pizzeria_ingredients_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.pizzeria_ingredients_id_seq TO service_role;


--
-- Name: TABLE pizzeria_products; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.pizzeria_products TO anon;
GRANT ALL ON TABLE public.pizzeria_products TO authenticated;
GRANT ALL ON TABLE public.pizzeria_products TO service_role;


--
-- Name: SEQUENCE pizzeria_products_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.pizzeria_products_id_seq TO anon;
GRANT ALL ON SEQUENCE public.pizzeria_products_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.pizzeria_products_id_seq TO service_role;


--
-- Name: TABLE pizzerias; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.pizzerias TO anon;
GRANT ALL ON TABLE public.pizzerias TO authenticated;
GRANT ALL ON TABLE public.pizzerias TO service_role;


--
-- Name: SEQUENCE pizzerias_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.pizzerias_id_seq TO anon;
GRANT ALL ON SEQUENCE public.pizzerias_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.pizzerias_id_seq TO service_role;


--
-- Name: TABLE slot_availability; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.slot_availability TO anon;
GRANT ALL ON TABLE public.slot_availability TO authenticated;
GRANT ALL ON TABLE public.slot_availability TO service_role;


--
-- Name: SEQUENCE slot_availability_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.slot_availability_id_seq TO anon;
GRANT ALL ON SEQUENCE public.slot_availability_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.slot_availability_id_seq TO service_role;


--
-- Name: TABLE slot_config; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.slot_config TO anon;
GRANT ALL ON TABLE public.slot_config TO authenticated;
GRANT ALL ON TABLE public.slot_config TO service_role;


--
-- Name: SEQUENCE slot_config_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.slot_config_id_seq TO anon;
GRANT ALL ON SEQUENCE public.slot_config_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.slot_config_id_seq TO service_role;


--
-- Name: TABLE v_available_slots; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v_available_slots TO anon;
GRANT ALL ON TABLE public.v_available_slots TO authenticated;
GRANT ALL ON TABLE public.v_available_slots TO service_role;


--
-- Name: TABLE v_pizzeria_menu; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.v_pizzeria_menu TO anon;
GRANT ALL ON TABLE public.v_pizzeria_menu TO authenticated;
GRANT ALL ON TABLE public.v_pizzeria_menu TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: postgres
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: supabase_admin
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- PostgreSQL database dump complete
--

\unrestrict bbMBYblBny5ln0be37ffUDg3bObGgblPfH6z8d5m9A70riBNf5WplxfcBBTJTIN

