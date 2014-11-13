--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

SET search_path = public, pg_catalog;

--
-- Name: frequency; Type: DOMAIN; Schema: public; Owner: mapasculturais
--

CREATE DOMAIN frequency AS character varying
	CONSTRAINT frequency_check CHECK (((VALUE)::text = ANY (ARRAY[('once'::character varying)::text, ('daily'::character varying)::text, ('weekly'::character varying)::text, ('monthly'::character varying)::text, ('yearly'::character varying)::text])));


ALTER DOMAIN public.frequency OWNER TO mapasculturais;

--
-- Name: days_in_month(date); Type: FUNCTION; Schema: public; Owner: mapasculturais
--

CREATE FUNCTION days_in_month(check_date date) RETURNS integer
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
  first_of_month DATE := check_date - ((extract(day from check_date) - 1)||' days')::interval;
BEGIN
  RETURN extract(day from first_of_month + '1 month'::interval - first_of_month);
END;
$$;


ALTER FUNCTION public.days_in_month(check_date date) OWNER TO mapasculturais;

--
-- Name: generate_recurrences(interval, date, date, date, date, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: mapasculturais
--

CREATE FUNCTION generate_recurrences(duration interval, original_start_date date, original_end_date date, range_start date, range_end date, repeat_month integer, repeat_week integer, repeat_day integer) RETURNS SETOF date
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
  start_date DATE := original_start_date;
  next_date DATE;
  intervals INT := FLOOR(intervals_between(original_start_date, range_start, duration));
  current_month INT;
  current_week INT;
BEGIN
  IF repeat_month IS NOT NULL THEN
    start_date := start_date + (((12 + repeat_month - cast(extract(month from start_date) as int)) % 12) || ' months')::interval;
  END IF;
  IF repeat_week IS NULL AND repeat_day IS NOT NULL THEN
    IF duration = '7 days'::interval THEN
      start_date := start_date + (((7 + repeat_day - cast(extract(dow from start_date) as int)) % 7) || ' days')::interval;
    ELSE
      start_date := start_date + (repeat_day - extract(day from start_date) || ' days')::interval;
    END IF;
  END IF;
  LOOP
    next_date := start_date + duration * intervals;
    IF repeat_week IS NOT NULL AND repeat_day IS NOT NULL THEN
      current_month := extract(month from next_date);
      next_date := next_date + (((7 + repeat_day - cast(extract(dow from next_date) as int)) % 7) || ' days')::interval;
      IF extract(month from next_date) != current_month THEN
        next_date := next_date - '7 days'::interval;
      END IF;
      IF repeat_week > 0 THEN
        current_week := CEIL(extract(day from next_date) / 7);
      ELSE
        current_week := -CEIL((1 + days_in_month(next_date) - extract(day from next_date)) / 7);
      END IF;
      next_date := next_date + (repeat_week - current_week) * '7 days'::interval;
    END IF;
    EXIT WHEN next_date > range_end;

    IF next_date >= range_start AND next_date >= original_start_date THEN
      RETURN NEXT next_date;
    END IF;

    if original_end_date IS NOT NULL AND range_start >= original_start_date + (duration*intervals) AND range_start <= original_end_date + (duration*intervals) THEN
      RETURN NEXT next_date;
    END IF;
    intervals := intervals + 1;
  END LOOP;
END;
$$;


ALTER FUNCTION public.generate_recurrences(duration interval, original_start_date date, original_end_date date, range_start date, range_end date, repeat_month integer, repeat_week integer, repeat_day integer) OWNER TO mapasculturais;

--
-- Name: interval_for(frequency); Type: FUNCTION; Schema: public; Owner: mapasculturais
--

CREATE FUNCTION interval_for(recurs frequency) RETURNS interval
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
  IF recurs = 'daily' THEN
    RETURN '1 day'::interval;
  ELSIF recurs = 'weekly' THEN
    RETURN '7 days'::interval;
  ELSIF recurs = 'monthly' THEN
    RETURN '1 month'::interval;
  ELSIF recurs = 'yearly' THEN
    RETURN '1 year'::interval;
  ELSE
    RAISE EXCEPTION 'Recurrence % not supported by generate_recurrences()', recurs;
  END IF;
END;
$$;


ALTER FUNCTION public.interval_for(recurs frequency) OWNER TO mapasculturais;

--
-- Name: intervals_between(date, date, interval); Type: FUNCTION; Schema: public; Owner: mapasculturais
--

CREATE FUNCTION intervals_between(start_date date, end_date date, duration interval) RETURNS double precision
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
  count FLOAT := 0;
  multiplier INT := 512;
BEGIN
  IF start_date > end_date THEN
    RETURN 0;
  END IF;
  LOOP
    WHILE start_date + (count + multiplier) * duration < end_date LOOP
      count := count + multiplier;
    END LOOP;
    EXIT WHEN multiplier = 1;
    multiplier := multiplier / 2;
  END LOOP;
  count := count + (extract(epoch from end_date) - extract(epoch from (start_date + count * duration))) / (extract(epoch from end_date + duration) - extract(epoch from end_date))::int;
  RETURN count;
END
$$;


ALTER FUNCTION public.intervals_between(start_date date, end_date date, duration interval) OWNER TO mapasculturais;

SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: event_occurrence; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE event_occurrence (
    id integer NOT NULL,
    space_id integer NOT NULL,
    event_id integer NOT NULL,
    rule text,
    starts_on date,
    ends_on date,
    starts_at timestamp without time zone,
    ends_at timestamp without time zone,
    frequency frequency,
    separation integer DEFAULT 1 NOT NULL,
    count integer,
    until date,
    timezone_name text DEFAULT 'Etc/UTC'::text NOT NULL,
    status integer DEFAULT 1 NOT NULL,
    CONSTRAINT positive_separation CHECK ((separation > 0))
);


ALTER TABLE public.event_occurrence OWNER TO mapasculturais;

--
-- Name: recurrences_for(event_occurrence, timestamp without time zone, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: mapasculturais
--

CREATE FUNCTION recurrences_for(event event_occurrence, range_start timestamp without time zone, range_end timestamp without time zone) RETURNS SETOF date
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  recurrence event_occurrence_recurrence;
  recurrences_start DATE := COALESCE(event.starts_at::date, event.starts_on);
  recurrences_end DATE := range_end;
  duration INTERVAL := interval_for(event.frequency) * event.separation;
  next_date DATE;
BEGIN
  IF event.until IS NOT NULL AND event.until < recurrences_end THEN
    recurrences_end := event.until;
  END IF;
  IF event.count IS NOT NULL AND recurrences_start + (event.count - 1) * duration < recurrences_end THEN
    recurrences_end := recurrences_start + (event.count - 1) * duration;
  END IF;

  FOR recurrence IN
    SELECT event_occurrence_recurrence.*
      FROM (SELECT NULL) AS foo
      LEFT JOIN event_occurrence_recurrence
        ON event_occurrence_id = event.id
  LOOP
    FOR next_date IN
      SELECT *
        FROM generate_recurrences(
          duration,
          recurrences_start,
          COALESCE(event.ends_at::date, event.ends_on),
          range_start::date,
          recurrences_end,
          recurrence.month,
          recurrence.week,
          recurrence.day
        )
    LOOP
      RETURN NEXT next_date;
    END LOOP;
  END LOOP;
  RETURN;
END;
$$;


ALTER FUNCTION public.recurrences_for(event event_occurrence, range_start timestamp without time zone, range_end timestamp without time zone) OWNER TO mapasculturais;

--
-- Name: recurring_event_occurrence_for(timestamp without time zone, timestamp without time zone, character varying, integer); Type: FUNCTION; Schema: public; Owner: mapasculturais
--

CREATE FUNCTION recurring_event_occurrence_for(range_start timestamp without time zone, range_end timestamp without time zone, time_zone character varying, event_occurrence_limit integer) RETURNS SETOF event_occurrence
    LANGUAGE plpgsql STABLE
    AS $$
            DECLARE
              event event_occurrence;
              original_date DATE;
              original_date_in_zone DATE;
              start_time TIME;
              start_time_in_zone TIME;
              next_date DATE;
              next_time_in_zone TIME;
              duration INTERVAL;
              time_offset INTERVAL;
              r_start DATE := (timezone('UTC', range_start) AT TIME ZONE time_zone)::DATE;
              r_end DATE := (timezone('UTC', range_end) AT TIME ZONE time_zone)::DATE;

              recurrences_start DATE := CASE WHEN r_start < range_start THEN r_start ELSE range_start END;
              recurrences_end DATE := CASE WHEN r_end > range_end THEN r_end ELSE range_end END;

              inc_interval INTERVAL := '2 hours'::INTERVAL;

              ext_start TIMESTAMP := range_start::TIMESTAMP - inc_interval;
              ext_end   TIMESTAMP := range_end::TIMESTAMP   + inc_interval;
            BEGIN
              FOR event IN
                SELECT *
                  FROM event_occurrence
                  WHERE
                    status > 0
                    AND
                    (
                      (frequency = 'once' AND
                      ((starts_on IS NOT NULL AND ends_on IS NOT NULL AND starts_on <= r_end AND ends_on >= r_start) OR
                       (starts_on IS NOT NULL AND starts_on <= r_end AND starts_on >= r_start) OR
                       (starts_at <= range_end AND ends_at >= range_start)))

                      OR

                      (
                        frequency <> 'once' AND
                        (
                          ( starts_on IS NOT NULL AND starts_on <= ext_end ) OR
                          ( starts_at IS NOT NULL AND starts_at <= ext_end )
                        ) AND (
                          (until IS NULL AND ends_at IS NULL AND ends_on IS NULL) OR
                          (until IS NOT NULL AND until >= ext_start) OR
                          (ends_on IS NOT NULL AND ends_on >= ext_start) OR
                          (ends_at IS NOT NULL AND ends_at >= ext_start)
                        )
                      )
                    )

              LOOP
                IF event.frequency = 'once' THEN
                  RETURN NEXT event;
                  CONTINUE;
                END IF;

                -- All-day event
                IF event.starts_on IS NOT NULL AND event.ends_on IS NULL THEN
                  original_date := event.starts_on;
                  duration := '1 day'::interval;
                -- Multi-day event
                ELSIF event.starts_on IS NOT NULL AND event.ends_on IS NOT NULL THEN
                  original_date := event.starts_on;
                  duration := timezone(time_zone, event.ends_on) - timezone(time_zone, event.starts_on);
                -- Timespan event
                ELSE
                  original_date := event.starts_at::date;
                  original_date_in_zone := (timezone('UTC', event.starts_at) AT TIME ZONE event.timezone_name)::date;
                  start_time := event.starts_at::time;
                  start_time_in_zone := (timezone('UTC', event.starts_at) AT time ZONE event.timezone_name)::time;
                  duration := event.ends_at - event.starts_at;
                END IF;

                IF event.count IS NOT NULL THEN
                  recurrences_start := original_date;
                END IF;

                FOR next_date IN
                  SELECT occurrence
                    FROM (
                      SELECT * FROM recurrences_for(event, recurrences_start, recurrences_end) AS occurrence
                      UNION SELECT original_date
                      LIMIT event.count
                    ) AS occurrences
                    WHERE
                      occurrence::date <= recurrences_end AND
                      (occurrence + duration)::date >= recurrences_start AND
                      occurrence NOT IN (SELECT date FROM event_occurrence_cancellation WHERE event_occurrence_id = event.id)
                    LIMIT event_occurrence_limit
                LOOP
                  -- All-day event
                  IF event.starts_on IS NOT NULL AND event.ends_on IS NULL THEN
                    CONTINUE WHEN next_date < r_start OR next_date > r_end;
                    event.starts_on := next_date;

                  -- Multi-day event
                  ELSIF event.starts_on IS NOT NULL AND event.ends_on IS NOT NULL THEN
                    event.starts_on := next_date;
                    CONTINUE WHEN event.starts_on > r_end;
                    event.ends_on := next_date + duration;
                    CONTINUE WHEN event.ends_on < r_start;

                  -- Timespan event
                  ELSE
                    next_time_in_zone := (timezone('UTC', (next_date + start_time)) at time zone event.timezone_name)::time;
                    time_offset := (original_date_in_zone + next_time_in_zone) - (original_date_in_zone + start_time_in_zone);
                    event.starts_at := next_date + start_time - time_offset;

                    CONTINUE WHEN event.starts_at > range_end;
                    event.ends_at := event.starts_at + duration;
                    CONTINUE WHEN event.ends_at < range_start;
                  END IF;

                  RETURN NEXT event;
                END LOOP;
              END LOOP;
              RETURN;
            END;
            $$;


ALTER FUNCTION public.recurring_event_occurrence_for(range_start timestamp without time zone, range_end timestamp without time zone, time_zone character varying, event_occurrence_limit integer) OWNER TO mapasculturais;

--
-- Name: agent_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE agent_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.agent_id_seq OWNER TO mapasculturais;

--
-- Name: agent; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE agent (
    id integer DEFAULT nextval('agent_id_seq'::regclass) NOT NULL,
    user_id integer NOT NULL,
    type smallint NOT NULL,
    name character varying(255) NOT NULL,
    location point,
    _geo_location geography,
    short_description text,
    long_description text,
    create_timestamp timestamp without time zone NOT NULL,
    status smallint NOT NULL,
    is_verified boolean DEFAULT false NOT NULL,
    parent_id integer
);


ALTER TABLE public.agent OWNER TO mapasculturais;

--
-- Name: COLUMN agent.location; Type: COMMENT; Schema: public; Owner: mapasculturais
--

COMMENT ON COLUMN agent.location IS 'type=POINT';


--
-- Name: agent_meta; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE agent_meta (
    object_id integer NOT NULL,
    key character varying(32) NOT NULL,
    value text
);


ALTER TABLE public.agent_meta OWNER TO mapasculturais;

--
-- Name: agent_relation; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE agent_relation (
    id integer NOT NULL,
    agent_id integer NOT NULL,
    object_type character varying(255) NOT NULL,
    object_id integer NOT NULL,
    type character varying(64),
    has_control boolean DEFAULT false NOT NULL,
    create_timestamp timestamp without time zone,
    status smallint
);


ALTER TABLE public.agent_relation OWNER TO mapasculturais;

--
-- Name: agent_relation_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE agent_relation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.agent_relation_id_seq OWNER TO mapasculturais;

--
-- Name: agent_relation_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: mapasculturais
--

ALTER SEQUENCE agent_relation_id_seq OWNED BY agent_relation.id;


--
-- Name: db_update; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE db_update (
    name character varying(255) NOT NULL,
    exec_time timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.db_update OWNER TO mapasculturais;

--
-- Name: event; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE event (
    id integer NOT NULL,
    project_id integer,
    name character varying(255) NOT NULL,
    short_description text NOT NULL,
    long_description text,
    rules text,
    create_timestamp timestamp without time zone NOT NULL,
    status smallint NOT NULL,
    agent_id integer,
    is_verified boolean DEFAULT false NOT NULL,
    type smallint NOT NULL
);


ALTER TABLE public.event OWNER TO mapasculturais;

--
-- Name: event_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.event_id_seq OWNER TO mapasculturais;

--
-- Name: event_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: mapasculturais
--

ALTER SEQUENCE event_id_seq OWNED BY event.id;


--
-- Name: event_meta; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE event_meta (
    key character varying(32) NOT NULL,
    object_id integer NOT NULL,
    value text
);


ALTER TABLE public.event_meta OWNER TO mapasculturais;

--
-- Name: event_occurrence_cancellation; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE event_occurrence_cancellation (
    id integer NOT NULL,
    event_occurrence_id integer,
    date date
);


ALTER TABLE public.event_occurrence_cancellation OWNER TO mapasculturais;

--
-- Name: event_occurrence_cancellation_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE event_occurrence_cancellation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.event_occurrence_cancellation_id_seq OWNER TO mapasculturais;

--
-- Name: event_occurrence_cancellation_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: mapasculturais
--

ALTER SEQUENCE event_occurrence_cancellation_id_seq OWNED BY event_occurrence_cancellation.id;


--
-- Name: event_occurrence_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE event_occurrence_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.event_occurrence_id_seq OWNER TO mapasculturais;

--
-- Name: event_occurrence_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: mapasculturais
--

ALTER SEQUENCE event_occurrence_id_seq OWNED BY event_occurrence.id;


--
-- Name: event_occurrence_recurrence; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE event_occurrence_recurrence (
    id integer NOT NULL,
    event_occurrence_id integer,
    month integer,
    day integer,
    week integer
);


ALTER TABLE public.event_occurrence_recurrence OWNER TO mapasculturais;

--
-- Name: event_occurrence_recurrence_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE event_occurrence_recurrence_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.event_occurrence_recurrence_id_seq OWNER TO mapasculturais;

--
-- Name: event_occurrence_recurrence_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: mapasculturais
--

ALTER SEQUENCE event_occurrence_recurrence_id_seq OWNED BY event_occurrence_recurrence.id;


--
-- Name: file_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE file_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.file_id_seq OWNER TO mapasculturais;

--
-- Name: file; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE file (
    id integer DEFAULT nextval('file_id_seq'::regclass) NOT NULL,
    md5 character varying(32) NOT NULL,
    mime_type character varying(255) NOT NULL,
    name character varying(255) NOT NULL,
    object_type character varying(255) NOT NULL,
    object_id integer NOT NULL,
    create_timestamp timestamp without time zone DEFAULT now() NOT NULL,
    grp character varying(32) NOT NULL,
    description character varying(255)
);


ALTER TABLE public.file OWNER TO mapasculturais;

--
-- Name: metadata; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE metadata (
    object_id integer NOT NULL,
    object_type character varying(255) NOT NULL,
    key character varying(32) NOT NULL,
    value text
);


ALTER TABLE public.metadata OWNER TO mapasculturais;

--
-- Name: metalist_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE metalist_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.metalist_id_seq OWNER TO mapasculturais;

--
-- Name: metalist; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE metalist (
    id integer DEFAULT nextval('metalist_id_seq'::regclass) NOT NULL,
    object_type character varying(255) NOT NULL,
    object_id integer NOT NULL,
    grp character varying(32) NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    value character varying(2048) NOT NULL,
    create_timestamp timestamp without time zone DEFAULT now() NOT NULL,
    "order" smallint
);


ALTER TABLE public.metalist OWNER TO mapasculturais;

--
-- Name: notification_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE notification_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.notification_id_seq OWNER TO mapasculturais;

--
-- Name: notification; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE notification (
    id integer DEFAULT nextval('notification_id_seq'::regclass) NOT NULL,
    user_id integer NOT NULL,
    request_id integer,
    message text NOT NULL,
    create_timestamp timestamp without time zone DEFAULT now() NOT NULL,
    action_timestamp timestamp without time zone,
    status smallint NOT NULL
);


ALTER TABLE public.notification OWNER TO mapasculturais;

--
-- Name: occurrence_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE occurrence_id_seq
    START WITH 100000
    INCREMENT BY 1
    MINVALUE 100000
    NO MAXVALUE
    CACHE 1
    CYCLE;


ALTER TABLE public.occurrence_id_seq OWNER TO mapasculturais;

--
-- Name: project; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE project (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    short_description text,
    long_description text,
    public_registration boolean NOT NULL,
    create_timestamp timestamp without time zone NOT NULL,
    status smallint NOT NULL,
    agent_id integer,
    is_verified boolean DEFAULT false NOT NULL,
    type smallint NOT NULL,
    parent_id integer,
    registration_from timestamp without time zone,
    registration_to timestamp without time zone
);


ALTER TABLE public.project OWNER TO mapasculturais;

--
-- Name: project_event; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE project_event (
    id integer NOT NULL,
    event_id integer NOT NULL,
    project_id integer NOT NULL,
    type smallint NOT NULL,
    status smallint NOT NULL
);


ALTER TABLE public.project_event OWNER TO mapasculturais;

--
-- Name: project_event_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE project_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.project_event_id_seq OWNER TO mapasculturais;

--
-- Name: project_event_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: mapasculturais
--

ALTER SEQUENCE project_event_id_seq OWNED BY project_event.id;


--
-- Name: project_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE project_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.project_id_seq OWNER TO mapasculturais;

--
-- Name: project_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: mapasculturais
--

ALTER SEQUENCE project_id_seq OWNED BY project.id;


--
-- Name: project_meta; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE project_meta (
    object_id integer NOT NULL,
    key character varying(32) NOT NULL,
    value text
);


ALTER TABLE public.project_meta OWNER TO mapasculturais;

--
-- Name: registration_file_configuration; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE registration_file_configuration (
    id integer NOT NULL,
    project_id integer NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    required boolean DEFAULT false NOT NULL
);


ALTER TABLE public.registration_file_configuration OWNER TO mapasculturais;

--
-- Name: registration_file_configuration_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE registration_file_configuration_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.registration_file_configuration_id_seq OWNER TO mapasculturais;

--
-- Name: registration_file_configuration_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: mapasculturais
--

ALTER SEQUENCE registration_file_configuration_id_seq OWNED BY registration_file_configuration.id;


--
-- Name: registration_meta; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE registration_meta (
    object_id integer NOT NULL,
    key character varying(32) NOT NULL,
    value text
);


ALTER TABLE public.registration_meta OWNER TO mapasculturais;

--
-- Name: request_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE request_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.request_id_seq OWNER TO mapasculturais;

--
-- Name: request; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE request (
    id integer DEFAULT nextval('request_id_seq'::regclass) NOT NULL,
    request_uid character varying(32) NOT NULL,
    requester_user_id integer NOT NULL,
    origin_type character varying(255) NOT NULL,
    origin_id integer NOT NULL,
    destination_type character varying(255) NOT NULL,
    destination_id integer NOT NULL,
    metadata text,
    type character varying(255) NOT NULL,
    create_timestamp timestamp without time zone DEFAULT now() NOT NULL,
    action_timestamp timestamp without time zone,
    status smallint NOT NULL
);


ALTER TABLE public.request OWNER TO mapasculturais;

--
-- Name: role; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE role (
    id integer NOT NULL,
    usr_id integer NOT NULL,
    name character varying(32) NOT NULL
);


ALTER TABLE public.role OWNER TO mapasculturais;

--
-- Name: role_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE role_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.role_id_seq OWNER TO mapasculturais;

--
-- Name: role_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: mapasculturais
--

ALTER SEQUENCE role_id_seq OWNED BY role.id;


--
-- Name: space; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE space (
    id integer NOT NULL,
    parent_id integer,
    location point,
    _geo_location geography,
    name character varying(255) NOT NULL,
    short_description text,
    long_description text,
    create_timestamp timestamp without time zone DEFAULT now() NOT NULL,
    status smallint NOT NULL,
    type smallint NOT NULL,
    agent_id integer,
    is_verified boolean DEFAULT false NOT NULL,
    public boolean DEFAULT false NOT NULL
);


ALTER TABLE public.space OWNER TO mapasculturais;

--
-- Name: COLUMN space.location; Type: COMMENT; Schema: public; Owner: mapasculturais
--

COMMENT ON COLUMN space.location IS 'type=POINT';


--
-- Name: space_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE space_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.space_id_seq OWNER TO mapasculturais;

--
-- Name: space_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: mapasculturais
--

ALTER SEQUENCE space_id_seq OWNED BY space.id;


--
-- Name: space_meta; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE space_meta (
    object_id integer NOT NULL,
    key character varying(32) NOT NULL,
    value text
);


ALTER TABLE public.space_meta OWNER TO mapasculturais;

--
-- Name: term; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE term (
    id integer NOT NULL,
    taxonomy smallint DEFAULT 1 NOT NULL,
    term character varying(255) NOT NULL,
    description text
);


ALTER TABLE public.term OWNER TO mapasculturais;

--
-- Name: COLUMN term.taxonomy; Type: COMMENT; Schema: public; Owner: mapasculturais
--

COMMENT ON COLUMN term.taxonomy IS '1=tag';


--
-- Name: term_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE term_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.term_id_seq OWNER TO mapasculturais;

--
-- Name: term_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: mapasculturais
--

ALTER SEQUENCE term_id_seq OWNED BY term.id;


--
-- Name: term_relation; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE term_relation (
    term_id integer NOT NULL,
    object_type character varying(255) NOT NULL,
    object_id integer NOT NULL
);


ALTER TABLE public.term_relation OWNER TO mapasculturais;

--
-- Name: usr_id_seq; Type: SEQUENCE; Schema: public; Owner: mapasculturais
--

CREATE SEQUENCE usr_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.usr_id_seq OWNER TO mapasculturais;

--
-- Name: usr; Type: TABLE; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE TABLE usr (
    id integer DEFAULT nextval('usr_id_seq'::regclass) NOT NULL,
    auth_provider smallint NOT NULL,
    auth_uid character varying(512) NOT NULL,
    email character varying(255) NOT NULL,
    last_login_timestamp timestamp without time zone NOT NULL,
    create_timestamp timestamp without time zone DEFAULT now() NOT NULL,
    status smallint NOT NULL,
    profile_id integer
);


ALTER TABLE public.usr OWNER TO mapasculturais;

--
-- Name: COLUMN usr.auth_provider; Type: COMMENT; Schema: public; Owner: mapasculturais
--

COMMENT ON COLUMN usr.auth_provider IS '1=openid';


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY agent_relation ALTER COLUMN id SET DEFAULT nextval('agent_relation_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY event ALTER COLUMN id SET DEFAULT nextval('event_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY event_occurrence ALTER COLUMN id SET DEFAULT nextval('event_occurrence_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY event_occurrence_cancellation ALTER COLUMN id SET DEFAULT nextval('event_occurrence_cancellation_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY event_occurrence_recurrence ALTER COLUMN id SET DEFAULT nextval('event_occurrence_recurrence_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY project ALTER COLUMN id SET DEFAULT nextval('project_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY project_event ALTER COLUMN id SET DEFAULT nextval('project_event_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY registration_file_configuration ALTER COLUMN id SET DEFAULT nextval('registration_file_configuration_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY role ALTER COLUMN id SET DEFAULT nextval('role_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY space ALTER COLUMN id SET DEFAULT nextval('space_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY term ALTER COLUMN id SET DEFAULT nextval('term_id_seq'::regclass);


--
-- Name: agent_meta_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY agent_meta
    ADD CONSTRAINT agent_meta_pk PRIMARY KEY (object_id, key);


--
-- Name: agent_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY agent
    ADD CONSTRAINT agent_pk PRIMARY KEY (id);


--
-- Name: agent_relation_pkey; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY agent_relation
    ADD CONSTRAINT agent_relation_pkey PRIMARY KEY (id);


--
-- Name: db_update_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY db_update
    ADD CONSTRAINT db_update_pk PRIMARY KEY (name);


--
-- Name: event_meta_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY event_meta
    ADD CONSTRAINT event_meta_pk PRIMARY KEY (key, object_id);


--
-- Name: event_occurrence_cancellation_pkey; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY event_occurrence_cancellation
    ADD CONSTRAINT event_occurrence_cancellation_pkey PRIMARY KEY (id);


--
-- Name: event_occurrence_pkey; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY event_occurrence
    ADD CONSTRAINT event_occurrence_pkey PRIMARY KEY (id);


--
-- Name: event_occurrence_recurrence_pkey; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY event_occurrence_recurrence
    ADD CONSTRAINT event_occurrence_recurrence_pkey PRIMARY KEY (id);


--
-- Name: event_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY event
    ADD CONSTRAINT event_pk PRIMARY KEY (id);


--
-- Name: file_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY file
    ADD CONSTRAINT file_pk PRIMARY KEY (id);


--
-- Name: metadata_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY metadata
    ADD CONSTRAINT metadata_pk PRIMARY KEY (object_id, object_type, key);


--
-- Name: metalist_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY metalist
    ADD CONSTRAINT metalist_pk PRIMARY KEY (id);


--
-- Name: notification_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY notification
    ADD CONSTRAINT notification_pk PRIMARY KEY (id);


--
-- Name: project_event_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY project_event
    ADD CONSTRAINT project_event_pk PRIMARY KEY (id);


--
-- Name: project_meta_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY project_meta
    ADD CONSTRAINT project_meta_pk PRIMARY KEY (object_id, key);


--
-- Name: project_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY project
    ADD CONSTRAINT project_pk PRIMARY KEY (id);


--
-- Name: registration_file_configuration_pkey; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY registration_file_configuration
    ADD CONSTRAINT registration_file_configuration_pkey PRIMARY KEY (id);


--
-- Name: registration_meta_pkey; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY registration_meta
    ADD CONSTRAINT registration_meta_pkey PRIMARY KEY (object_id, key);


--
-- Name: request_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY request
    ADD CONSTRAINT request_pk PRIMARY KEY (id);


--
-- Name: role_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY role
    ADD CONSTRAINT role_pk PRIMARY KEY (id);


--
-- Name: role_unique; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY role
    ADD CONSTRAINT role_unique UNIQUE (usr_id, name);


--
-- Name: space_meta_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY space_meta
    ADD CONSTRAINT space_meta_pk PRIMARY KEY (object_id, key);


--
-- Name: space_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY space
    ADD CONSTRAINT space_pk PRIMARY KEY (id);


--
-- Name: term_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY term
    ADD CONSTRAINT term_pk PRIMARY KEY (id);


--
-- Name: term_relation_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY term_relation
    ADD CONSTRAINT term_relation_pk PRIMARY KEY (term_id, object_type, object_id);


--
-- Name: usr_pk; Type: CONSTRAINT; Schema: public; Owner: mapasculturais; Tablespace:
--

ALTER TABLE ONLY usr
    ADD CONSTRAINT usr_pk PRIMARY KEY (id);


--
-- Name: agent_relation_all; Type: INDEX; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE INDEX agent_relation_all ON agent_relation USING btree (agent_id, object_type, object_id);


--
-- Name: event_occurrence_status_index; Type: INDEX; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE INDEX event_occurrence_status_index ON event_occurrence USING btree (status);


--
-- Name: registration_meta_key_value_index; Type: INDEX; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE INDEX registration_meta_key_value_index ON registration_meta USING btree (key, value);


--
-- Name: request_uid; Type: INDEX; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE UNIQUE INDEX request_uid ON request USING btree (request_uid);


--
-- Name: requester_user_index; Type: INDEX; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE INDEX requester_user_index ON request USING btree (requester_user_id, origin_type, origin_id);


--
-- Name: space_location; Type: INDEX; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE INDEX space_location ON space USING gist (_geo_location);


--
-- Name: space_type; Type: INDEX; Schema: public; Owner: mapasculturais; Tablespace:
--

CREATE INDEX space_type ON space USING btree (type);


--
-- Name: agent_agent_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY agent
    ADD CONSTRAINT agent_agent_fk FOREIGN KEY (parent_id) REFERENCES agent(id);


--
-- Name: agent_agent_meta_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY agent_meta
    ADD CONSTRAINT agent_agent_meta_fk FOREIGN KEY (object_id) REFERENCES agent(id);


--
-- Name: agent_relation_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY agent_relation
    ADD CONSTRAINT agent_relation_fk FOREIGN KEY (agent_id) REFERENCES agent(id);


--
-- Name: event_agent_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY event
    ADD CONSTRAINT event_agent_fk FOREIGN KEY (agent_id) REFERENCES agent(id);


--
-- Name: event_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY event_occurrence
    ADD CONSTRAINT event_fk FOREIGN KEY (event_id) REFERENCES event(id);


--
-- Name: event_occurrence_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY event_occurrence_cancellation
    ADD CONSTRAINT event_occurrence_fk FOREIGN KEY (event_occurrence_id) REFERENCES event_occurrence(id) ON DELETE CASCADE;


--
-- Name: event_occurrence_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY event_occurrence_recurrence
    ADD CONSTRAINT event_occurrence_fk FOREIGN KEY (event_occurrence_id) REFERENCES event_occurrence(id) ON DELETE CASCADE;


--
-- Name: event_project_event_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY project_event
    ADD CONSTRAINT event_project_event_fk FOREIGN KEY (event_id) REFERENCES event(id);


--
-- Name: event_project_meta_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY event_meta
    ADD CONSTRAINT event_project_meta_fk FOREIGN KEY (object_id) REFERENCES event(id);


--
-- Name: notification_request_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY notification
    ADD CONSTRAINT notification_request_fk FOREIGN KEY (request_id) REFERENCES request(id);


--
-- Name: notification_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY notification
    ADD CONSTRAINT notification_user_fk FOREIGN KEY (user_id) REFERENCES usr(id);


--
-- Name: project_agent_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY project
    ADD CONSTRAINT project_agent_fk FOREIGN KEY (agent_id) REFERENCES agent(id);


--
-- Name: project_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY event
    ADD CONSTRAINT project_fk FOREIGN KEY (project_id) REFERENCES project(id);


--
-- Name: project_project_event_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY project_event
    ADD CONSTRAINT project_project_event_fk FOREIGN KEY (project_id) REFERENCES project(id);


--
-- Name: project_project_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY project
    ADD CONSTRAINT project_project_fk FOREIGN KEY (parent_id) REFERENCES project(id);


--
-- Name: project_project_meta_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY project_meta
    ADD CONSTRAINT project_project_meta_fk FOREIGN KEY (object_id) REFERENCES project(id);


--
-- Name: registration_meta_project_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY registration_file_configuration
    ADD CONSTRAINT registration_meta_project_fk FOREIGN KEY (project_id) REFERENCES project(id) ON DELETE SET NULL;


--
-- Name: requester_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY request
    ADD CONSTRAINT requester_user_fk FOREIGN KEY (requester_user_id) REFERENCES usr(id);


--
-- Name: role_user_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY role
    ADD CONSTRAINT role_user_fk FOREIGN KEY (usr_id) REFERENCES usr(id) ON DELETE CASCADE;


--
-- Name: space_agent_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY space
    ADD CONSTRAINT space_agent_fk FOREIGN KEY (agent_id) REFERENCES agent(id);


--
-- Name: space_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY event_occurrence
    ADD CONSTRAINT space_fk FOREIGN KEY (space_id) REFERENCES space(id);


--
-- Name: space_space_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY space
    ADD CONSTRAINT space_space_fk FOREIGN KEY (parent_id) REFERENCES space(id);


--
-- Name: space_space_meta_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY space_meta
    ADD CONSTRAINT space_space_meta_fk FOREIGN KEY (object_id) REFERENCES space(id);


--
-- Name: term_term_relation_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY term_relation
    ADD CONSTRAINT term_term_relation_fk FOREIGN KEY (term_id) REFERENCES term(id);


--
-- Name: user_profile_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY usr
    ADD CONSTRAINT user_profile_fk FOREIGN KEY (profile_id) REFERENCES agent(id);


--
-- Name: usr_agent_fk; Type: FK CONSTRAINT; Schema: public; Owner: mapasculturais
--

ALTER TABLE ONLY agent
    ADD CONSTRAINT usr_agent_fk FOREIGN KEY (user_id) REFERENCES usr(id);



CREATE TABLE geo_division (
    id serial PRIMARY KEY,
    parent_id integer,
    type character varying(32) NOT NULL,
    cod character varying(32),
    name character varying(128) NOT NULL,
    geom geometry,
    CONSTRAINT enforce_dims_geom CHECK ((st_ndims(geom) = 2)),
    CONSTRAINT enforce_geotype_geom CHECK (((geometrytype(geom) = 'MULTIPOLYGON'::text) OR (geom IS NULL))),
    CONSTRAINT enforce_srid_geom CHECK ((st_srid(geom) = 4326))
);
CREATE INDEX geo_divisions_geom_idx ON geo_division USING gist (geom);


--
-- Name: public; Type: ACL; Schema: -; Owner: postgres
--

REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM postgres;
GRANT ALL ON SCHEMA public TO postgres;
GRANT ALL ON SCHEMA public TO PUBLIC;


--
-- PostgreSQL database dump complete
--
