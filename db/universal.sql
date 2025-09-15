CREATE EXTENSION earthdistance CASCADE;

-- Create the table
create table if not exists locations (
  id serial primary key,  -- Unique identifier for each entry
  "lat" float8,           -- Latitude of the location
  "lon" float8,           -- Longitude of the location
  "acc" int,              -- Accuracy of the reported location in meters
  "alt" int,              -- Altitude above sea level in meters
  "vel" int,              -- Velocity in km/h
  "vac" int,              -- Vertical accuracy of the altitude in meters
  "p" float8,             -- Barometric pressure in kPa
  "cog" int,              -- Course over ground in degrees
  "rad" int,              -- Radius around the region in meters
  "tst" int8,             -- UNIX epoch timestamp of the location fix
  "created_at" int8,      -- Timestamp when the message is constructed
  "tag" varchar,          -- Custom tag
  "topic" varchar,        -- MQTT topic
  "_type" varchar,        -- Type of the payload
  "tid" varchar(2),       -- Tracker ID used to display the initials of a user
  "conn" varchar,         -- Internet connectivity status
  "batt" int,             -- Device battery level in percent
  "bs" int,               -- Battery status (0=unknown, 1=unplugged, 2=charging, 3=full)
  "w" boolean,            -- Indicates if the phone is connected to WiFi
  "o" boolean,            -- Indicates if the phone is offline
  "m" int,                -- Monitoring mode (1=significant, 2=move)
  "ssid" varchar,         -- SSID of the WiFi
  "bssid" varchar,        -- BSSID of the WiFi
  "inregions" text[],     -- List of regions the device is currently in
  "inrids" text[],        -- List of region IDs the device is currently in
  "desc" varchar,         -- Description (used for waypoints and transitions)
  "uuid" varchar,         -- UUID of the BLE Beacon
  "major" int,            -- Major number of the BLE Beacon
  "minor" int,            -- Minor number of the BLE Beacon
  "event" varchar,        -- Event that triggered the transition
  "wtst" int8,            -- Timestamp of waypoint creation
  "poi" varchar,          -- Point of interest name
  "r" varchar,            -- Response to a reportLocation cmd message
  "u" varchar,            -- Manual publish requested by the user
  "t" varchar,            -- Trigger for the location report
  "c" varchar,            -- Circular region enter/leave event
  "b" varchar,            -- Beacon region enter/leave event
  "face" text,            -- Base64 encoded PNG image for user icon
  "steps" int,            -- Steps walked with the device
  "from_epoch" int8,      -- Effective start of time period for steps
  "to_epoch" int8,        -- Effective end of time period for steps
  "data" text,            -- Encrypted and Base64 encoded original JSON message
  "request" varchar       -- Request type (e.g., "tour")
);

-- Add indexes
create index if not exists idx_locations_tid on locations(tid, tst);

-- Enable RLS
alter table locations enable row level security;

-- Drop existing policy if it exists
drop policy if exists "Enable insert access for all users" on "public"."locations";

-- Create policy for anonymous users to insert
create policy "Enable insert access for all users"
on "public"."locations"
for insert
to anon
with check (true);

-- Automatically detect if reporter stays in 1 place
CREATE OR REPLACE VIEW locations_no_dups AS
SELECT *
FROM locations;

GRANT INSERT ON locations_no_dups TO anon;

CREATE OR REPLACE FUNCTION locations_no_dups_insert_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER  -- run with owner's privileges
AS $$
DECLARE
	PREV_LOCATIONS_LEN CONSTANT INT := 6;
    CUR_LOCATIONS_LEN CONSTANT INT := 6;
    MAX_PROXIMITY_METERS CONSTANT INT := 20;

    prev_lat FLOAT8;
	prev_lon FLOAT8;
	prev_alt FLOAT8;
	cur_lat FLOAT8;
	cur_lon FLOAT8;
	cur_alt FLOAT8;
	cur_group_oldest_id BIGINT;
	result locations;
BEGIN
    -- Find median of previous locations
	WITH prev AS (
		SELECT *
		FROM locations
		WHERE tid = NEW.tid
			AND lat IS NOT NULL
			AND lon IS NOT NULL
			AND tst IS NOT NULL
		ORDER BY tst DESC, id DESC
		LIMIT PREV_LOCATIONS_LEN
		OFFSET CUR_LOCATIONS_LEN
	)
	SELECT
		percentile_cont(0.5) WITHIN GROUP (ORDER BY lat),
		percentile_cont(0.5) WITHIN GROUP (ORDER BY lon),
		percentile_cont(0.5) WITHIN GROUP (ORDER BY alt)
	INTO
		prev_lat, prev_lon, prev_alt
	FROM prev;

	-- Find median of current locations
	WITH recent AS (
		SELECT *
		FROM locations
		WHERE tid = NEW.tid
			AND lat IS NOT NULL
			AND lon IS NOT NULL
			AND tst IS NOT NULL
		ORDER BY tst DESC, id DESC
		LIMIT CUR_LOCATIONS_LEN
	)
	SELECT
		(SELECT id FROM recent ORDER BY tst, id LIMIT 1),
		percentile_cont(0.5) WITHIN GROUP (ORDER BY lat),
		percentile_cont(0.5) WITHIN GROUP (ORDER BY lon),
		percentile_cont(0.5) WITHIN GROUP (ORDER BY alt)
	INTO
		cur_group_oldest_id,
		cur_lat, cur_lon, cur_alt
	FROM recent;

    -- Check if we should rotate or insert
    -- 1. The most recent location must be valid (non-null lat/lon)
    -- 2. The most recent location must be within range
    -- 3. At least MIN_WITHIN_RANGE locations must be within the hangout distance
    IF
		cur_group_oldest_id IS NOT NULL
		AND prev_lat IS NOT NULL
		AND prev_lon IS NOT NULL
		AND cur_lat IS NOT NULL
		AND cur_lon IS NOT NULL
		AND earth_distance(
			ll_to_earth(prev_lat, prev_lon),
			ll_to_earth(cur_lat, cur_lon)
		) < MAX_PROXIMITY_METERS
    THEN
		-- Rotate: delete the oldest in the current group and insert the new one
		--         no one `current` location becomes `previous`
        DELETE FROM locations
        WHERE id = cur_group_oldest_id;
    ELSE
        -- Insert new location; the oldest `current` location becomes `previous`
    END IF;

	NEW.id := nextval('locations_id_seq');

	INSERT INTO locations
	SELECT NEW.*
	RETURNING * INTO result;

	RETURN result;
END;
$$;

CREATE OR REPLACE TRIGGER trg_locations_no_dups_insert_trigger
INSTEAD OF INSERT ON locations_no_dups
FOR EACH ROW
EXECUTE FUNCTION locations_no_dups_insert_trigger();


CREATE OR REPLACE FUNCTION insert_or_update_location_json(new_loc_json json)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER  -- run with owner's privileges
AS $$
DECLARE
    new_loc locations;
BEGIN
    -- Populate the record from JSON
    SELECT * INTO new_loc
    FROM json_populate_record(NULL::locations, new_loc_json);

    INSERT INTO locations_no_dups
    SELECT new_loc.*;
END;
$$;
