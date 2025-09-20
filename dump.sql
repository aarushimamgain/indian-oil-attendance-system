

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."check_mid_swipe_gaps"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  swipe_times TIMESTAMP[];
  i INT;
BEGIN
  -- Get all swipes for that employee on that date, ordered
  SELECT array_agg(swipe_time ORDER BY swipe_time)
  INTO swipe_times
  FROM swipe
  WHERE emp_no = NEW.emp_no
    AND DATE(swipe_time) = DATE(NEW.swipe_time);

  -- Check time gaps between mid-swipes (excluding first and last)
  FOR i IN 2..array_length(swipe_times, 1) - 1 LOOP
    IF swipe_times[i+1] - swipe_times[i] > INTERVAL '30 minutes' THEN
      -- Insert into approval_requests if a gap > 30 min found
      INSERT INTO approval_requests (emp_no, date, start_time, end_time, status)
      VALUES (
        NEW.emp_no,
        DATE(NEW.swipe_time),
        swipe_times[i],
        swipe_times[i+1],
        'pending'
      );
      EXIT; -- Only insert once per day
    END IF;
  END LOOP;

  RETURN NULL; -- Because it's an AFTER INSERT trigger
END;
$$;


ALTER FUNCTION "public"."check_mid_swipe_gaps"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_middle_gap"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.middle_in IS NOT NULL AND NEW.middle_out IS NOT NULL THEN
    IF EXTRACT(EPOCH FROM (NEW.middle_out - NEW.middle_in)) / 60 > 30 THEN
      INSERT INTO approval_requests (emp_no, date)
      VALUES (NEW.emp_no, NEW.date)
      ON CONFLICT (emp_no, date) DO NOTHING;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."check_middle_gap"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_middle_swipe_gap"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    emp TEXT;
    rec RECORD;
    mid_swipes TIMESTAMP[];
    time_gap_minutes INT;
BEGIN
    FOR rec IN
        SELECT DISTINCT emp_no, date FROM swipe_data
        WHERE date BETWEEN CURRENT_DATE - INTERVAL '10 days' AND CURRENT_DATE
    LOOP
        emp := rec.emp_no;

        -- Get all mid swipes (excluding first in and last out)
        SELECT ARRAY(
            SELECT swipe_time FROM swipe_data
            WHERE emp_no = emp AND date = rec.date
            ORDER BY swipe_time
            OFFSET 1
        ) INTO mid_swipes;

        IF array_length(mid_swipes, 1) > 2 THEN
            -- Calculate time difference between consecutive mid swipes
            FOR i IN 1..array_length(mid_swipes, 1) - 1 LOOP
                time_gap_minutes := EXTRACT(EPOCH FROM (mid_swipes[i+1] - mid_swipes[i])) / 60;

                IF time_gap_minutes > 30 THEN
                    INSERT INTO approval_requests (emp_no, date)
                    VALUES (emp, rec.date)
                    ON CONFLICT (emp_no, date) DO NOTHING;
                    EXIT;  -- Only one insert per employee-date
                END IF;
            END LOOP;
        END IF;

    END LOOP;
    RETURN NULL;
END;
$$;


ALTER FUNCTION "public"."check_middle_swipe_gap"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."raise_gap_approval"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  gaps RECORD;
BEGIN
  FOR gaps IN
    SELECT 
      s1.emp_no,
      DATE(s1.swipe_time) AS swipe_date,
      s1.swipe_time,
      s2.swipe_time AS next_swipe,
      EXTRACT(EPOCH FROM (s2.swipe_time - s1.swipe_time)) / 60 AS gap_minutes
    FROM swipe s1
    JOIN swipe s2 ON s1.emp_no = s2.emp_no
    WHERE DATE(s1.swipe_time) = DATE(NEW.swipe_time)
      AND s2.swipe_time > s1.swipe_time
      AND s1.emp_no = NEW.emp_no
    ORDER BY s1.swipe_time
  LOOP
    IF gaps.gap_minutes > 30 THEN
      INSERT INTO approval_requests (emp_no, date, reason)
      VALUES (gaps.emp_no, gaps.swipe_date, 'Swipe gap > 30 minutes')
      ON CONFLICT DO NOTHING;
      RETURN NEW;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."raise_gap_approval"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."approval_requests" (
    "emp_no" character varying NOT NULL,
    "date" "date" NOT NULL,
    "status" character varying,
    "reason" "text",
    "officer_id" character varying,
    CONSTRAINT "approval_requests_status_check" CHECK ((("status")::"text" = ANY (ARRAY[('pending'::character varying)::"text", ('approved'::character varying)::"text", ('rejected'::character varying)::"text"])))
);


ALTER TABLE "public"."approval_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."attendance" (
    "date" "date",
    "shift_in" timestamp without time zone,
    "shift_out" timestamp without time zone,
    "emp_no" integer,
    "shiftname" "text"
);


ALTER TABLE "public"."attendance" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."flag" (
    "device_id" integer,
    "flag" "text"
);


ALTER TABLE "public"."flag" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."swipe" (
    "device_id" integer,
    "swipe_time" timestamp without time zone,
    "emp_no" integer
);


ALTER TABLE "public"."swipe" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."swipe_view" WITH ("security_invoker"='on') AS
 SELECT "s"."emp_no",
    "date"("s"."swipe_time") AS "date",
    "s"."swipe_time",
    "f"."flag"
   FROM ("public"."swipe" "s"
     JOIN "public"."flag" "f" ON (("s"."device_id" = "f"."device_id")));


ALTER VIEW "public"."swipe_view" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."daily_attendance_summary" WITH ("security_invoker"='on') AS
 SELECT "emp_no",
    "date"("swipe_time") AS "date",
    "min"(
        CASE
            WHEN ("flag" = 'in'::"text") THEN "swipe_time"
            ELSE NULL::timestamp without time zone
        END) AS "first_in_time",
    "max"(
        CASE
            WHEN ("flag" = 'out'::"text") THEN "swipe_time"
            ELSE NULL::timestamp without time zone
        END) AS "last_out_time"
   FROM "public"."swipe_view"
  GROUP BY "emp_no", ("date"("swipe_time"));


ALTER VIEW "public"."daily_attendance_summary" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."timings" (
    "shiftname" "text" NOT NULL,
    "start_timing" time without time zone,
    "end_timing" time without time zone,
    "flexi_time" time without time zone
);


ALTER TABLE "public"."timings" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."calendar_view" AS
 WITH "attendance_logic" AS (
         SELECT "a"."emp_no",
            "a"."date",
            "a"."shift_in",
            "a"."shift_out",
            "fin"."first_in_time",
            "lout"."last_out_time",
            "a"."shiftname" AS "shift_name",
            "t"."flexi_time",
                CASE
                    WHEN ("t"."shiftname" = ANY (ARRAY['B'::"text", 'C'::"text"])) THEN
                    CASE
                        WHEN (("fin"."first_in_time" IS NOT NULL) AND ("lout"."last_out_time" IS NOT NULL)) THEN
                        CASE
                            WHEN (("fin"."first_in_time" <= "a"."shift_in") AND ("lout"."last_out_time" >= "a"."shift_out")) THEN 'Present'::"text"
                            WHEN ((("fin"."first_in_time" <= "a"."shift_in") AND ("lout"."last_out_time" >= ("a"."shift_in" + (("a"."shift_out" - "a"."shift_in") / (2)::double precision)))) OR (("fin"."first_in_time" <= ("a"."shift_in" + (("a"."shift_out" - "a"."shift_in") / (2)::double precision))) AND ("lout"."last_out_time" >= "a"."shift_out"))) THEN 'Half Day'::"text"
                            ELSE 'Absent'::"text"
                        END
                        WHEN (("fin"."first_in_time" IS NOT NULL) OR ("lout"."last_out_time" IS NOT NULL)) THEN 'Half Day'::"text"
                        ELSE 'Absent'::"text"
                    END
                    ELSE
                    CASE
                        WHEN (("fin"."first_in_time" IS NOT NULL) AND ("lout"."last_out_time" IS NOT NULL)) THEN
                        CASE
                            WHEN (((EXTRACT(epoch FROM ("lout"."last_out_time" - "fin"."first_in_time")) / (3600)::numeric) >= (EXTRACT(epoch FROM ("t"."end_timing" - "t"."start_timing")) / (3600)::numeric)) AND ((("fin"."first_in_time")::time without time zone >= ("t"."start_timing" - (("t"."flexi_time" || ' minutes'::"text"))::interval)) AND (("fin"."first_in_time")::time without time zone <= ("t"."start_timing" + (("t"."flexi_time" || ' minutes'::"text"))::interval)))) THEN 'Present'::"text"
                            WHEN (((("fin"."first_in_time")::time without time zone >= ("t"."start_timing" - (("t"."flexi_time" || ' minutes'::"text"))::interval)) AND (("fin"."first_in_time")::time without time zone <= ("t"."start_timing" + (("t"."flexi_time" || ' minutes'::"text"))::interval))) OR (("t"."shiftname" <> 'C'::"text") AND (("lout"."last_out_time")::time without time zone >= ("t"."end_timing" - (("t"."flexi_time" || ' minutes'::"text"))::interval)))) THEN 'Half Day'::"text"
                            ELSE 'Absent'::"text"
                        END
                        WHEN (("fin"."first_in_time" IS NOT NULL) OR ("lout"."last_out_time" IS NOT NULL)) THEN 'Half Day'::"text"
                        ELSE 'Absent'::"text"
                    END
                END AS "attendance_status"
           FROM ((("public"."attendance" "a"
             LEFT JOIN "public"."timings" "t" ON (("a"."shiftname" = "t"."shiftname")))
             LEFT JOIN "public"."daily_attendance_summary" "fin" ON ((("a"."emp_no" = "fin"."emp_no") AND ("a"."date" = "fin"."date"))))
             LEFT JOIN "public"."daily_attendance_summary" "lout" ON ((("a"."emp_no" = "lout"."emp_no") AND ((("a"."shiftname" = 'C'::"text") AND ("lout"."date" = ("a"."date" + '1 day'::interval))) OR (("a"."shiftname" <> 'C'::"text") AND ("lout"."date" = "a"."date"))))))
        )
 SELECT "main"."emp_no",
    "main"."date",
    "main"."shift_in",
    "main"."shift_out",
    "main"."first_in_time",
    "main"."last_out_time",
    "main"."shift_name",
    "main"."flexi_time",
    "main"."attendance_status",
        CASE
            WHEN (("ar"."emp_no" IS NOT NULL) AND ("ar"."status" IS NULL)) THEN 'Pending Approval'::"text"
            ELSE "main"."attendance_status"
        END AS "status"
   FROM ("attendance_logic" "main"
     LEFT JOIN "public"."approval_requests" "ar" ON (((("ar"."emp_no")::integer = "main"."emp_no") AND ("ar"."date" = "main"."date"))));


ALTER VIEW "public"."calendar_view" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."shifts" (
    "emp_no" integer NOT NULL,
    "shiftname" "text"
);


ALTER TABLE "public"."shifts" OWNER TO "postgres";


ALTER TABLE "public"."shifts" ALTER COLUMN "emp_no" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."shifts_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."approval_requests"
    ADD CONSTRAINT "approval_requests_pkey" PRIMARY KEY ("emp_no", "date");



ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_pkey" PRIMARY KEY ("emp_no");



ALTER TABLE ONLY "public"."timings"
    ADD CONSTRAINT "timings_pkey" PRIMARY KEY ("shiftname");



CREATE OR REPLACE TRIGGER "check_gap_trigger" AFTER INSERT ON "public"."swipe" FOR EACH STATEMENT EXECUTE FUNCTION "public"."check_middle_swipe_gap"();



CREATE OR REPLACE TRIGGER "detect_swipe_gap" AFTER INSERT ON "public"."swipe" FOR EACH ROW EXECUTE FUNCTION "public"."raise_gap_approval"();



CREATE OR REPLACE TRIGGER "trg_check_middle_gap" AFTER INSERT OR UPDATE ON "public"."swipe" FOR EACH ROW EXECUTE FUNCTION "public"."check_middle_gap"();



CREATE OR REPLACE TRIGGER "trg_check_swipe_gaps" AFTER INSERT ON "public"."swipe" FOR EACH ROW EXECUTE FUNCTION "public"."check_mid_swipe_gaps"();





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

























































































































































GRANT ALL ON FUNCTION "public"."check_mid_swipe_gaps"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_mid_swipe_gaps"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_mid_swipe_gaps"() TO "service_role";



GRANT ALL ON FUNCTION "public"."check_middle_gap"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_middle_gap"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_middle_gap"() TO "service_role";



GRANT ALL ON FUNCTION "public"."check_middle_swipe_gap"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_middle_swipe_gap"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_middle_swipe_gap"() TO "service_role";



GRANT ALL ON FUNCTION "public"."raise_gap_approval"() TO "anon";
GRANT ALL ON FUNCTION "public"."raise_gap_approval"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."raise_gap_approval"() TO "service_role";


















GRANT ALL ON TABLE "public"."approval_requests" TO "anon";
GRANT ALL ON TABLE "public"."approval_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."approval_requests" TO "service_role";



GRANT ALL ON TABLE "public"."attendance" TO "anon";
GRANT ALL ON TABLE "public"."attendance" TO "authenticated";
GRANT ALL ON TABLE "public"."attendance" TO "service_role";



GRANT ALL ON TABLE "public"."flag" TO "anon";
GRANT ALL ON TABLE "public"."flag" TO "authenticated";
GRANT ALL ON TABLE "public"."flag" TO "service_role";



GRANT ALL ON TABLE "public"."swipe" TO "anon";
GRANT ALL ON TABLE "public"."swipe" TO "authenticated";
GRANT ALL ON TABLE "public"."swipe" TO "service_role";



GRANT ALL ON TABLE "public"."swipe_view" TO "anon";
GRANT ALL ON TABLE "public"."swipe_view" TO "authenticated";
GRANT ALL ON TABLE "public"."swipe_view" TO "service_role";



GRANT ALL ON TABLE "public"."daily_attendance_summary" TO "anon";
GRANT ALL ON TABLE "public"."daily_attendance_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_attendance_summary" TO "service_role";



GRANT ALL ON TABLE "public"."timings" TO "anon";
GRANT ALL ON TABLE "public"."timings" TO "authenticated";
GRANT ALL ON TABLE "public"."timings" TO "service_role";



GRANT ALL ON TABLE "public"."calendar_view" TO "anon";
GRANT ALL ON TABLE "public"."calendar_view" TO "authenticated";
GRANT ALL ON TABLE "public"."calendar_view" TO "service_role";



GRANT ALL ON TABLE "public"."shifts" TO "anon";
GRANT ALL ON TABLE "public"."shifts" TO "authenticated";
GRANT ALL ON TABLE "public"."shifts" TO "service_role";



GRANT ALL ON SEQUENCE "public"."shifts_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."shifts_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."shifts_id_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






























RESET ALL;
