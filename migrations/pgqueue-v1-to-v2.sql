--
-- PGQueue v2
--
-- This migration script will upgrade the PGQueue schema from v1 to v2.
-- It adds POLL as a new job type.
-- POLL jobs are skipped by the workers and can be polled by clients
-- through a special RPC call.
--

-- Add POLL to job_type enum
ALTER TYPE pgqueue.job_type ADD VALUE 'POLL';

-- Add polled to job_status enum
ALTER TYPE pgqueue.job_status ADD VALUE 'polled';

--
-- RPC function to look for non-completed POLL jobs
-- If a job is found, it is marked as polled and returned to the client
-- for processing. The client must acknowledge the job after processing.
-- If the job is not acknowledged within 60 seconds, it will be
-- marked as failed and picked up by the next poll again.
--
CREATE OR REPLACE FUNCTION public.pgqueue_poll_job(
    _job_owner TEXT,
    _timestamp numeric,
    _hmac TEXT,
    _user BOOLEAN DEFAULT FALSE,
    _auto_ack BOOLEAN DEFAULT FALSE
)
RETURNS TEXT 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    _job RECORD;
    _string_to_sign TEXT;
BEGIN
    -- Form the string to be signed
    IF _user THEN
        _string_to_sign := 
            _job_owner 
            || _timestamp::TEXT 
            || auth.uid()
            || 'POLL';
    ELSE
        _string_to_sign := 
            _job_owner 
            || _timestamp::TEXT 
            || 'POLL';
    END IF;

    -- Check if the timestamp is too old
    IF _timestamp < extract(epoch from now()) - 2 THEN
        RAISE EXCEPTION 'Timestamp too old';
    END IF;

    -- Select the first job that matches the criteria
    SELECT jq.*
    INTO _job
    FROM pgqueue.job_queue jq
    LEFT JOIN vault.decrypted_secrets ds 
      ON jq.signing_vault = ds.name  -- Match signing_vault with name in decrypted_secrets table
    WHERE jq.job_type = 'POLL'
    AND jq.run_at <= now()
    AND jq.job_owner = _job_owner
    AND jq.job_status = 'new'
    AND encode(
        hmac(
            _string_to_sign::bytea, 
            -- Use decrypted secret if available, else signing_secret
            COALESCE(ds.decrypted_secret, jq.signing_secret),
            'sha256'
        ), 
        'hex'
    ) = _hmac
    ORDER BY jq.run_at
    LIMIT 1
    FOR UPDATE; -- Lock the row for update

    -- If no job found, return NULL
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- Update the status to polled or completed if auto_ack
    IF _auto_ack THEN
        UPDATE pgqueue.job_queue
        SET job_status = 'completed', last_at = now()
        WHERE id = _job.id;
    ELSE THEN
        UPDATE pgqueue.job_queue
        SET
            job_status = 'polled', 
            last_at = now(), 
            run_at = now() + INTERVAL '60 seconds' -- 60 seconds to acknowledge
        WHERE id = _job.id;
    END IF;

    -- Return the combined payload and headers as JSON
    RETURN jsonb_build_object(
        'id', _job.id,
        'payload', _job.payload,
        'headers', _job.headers
    )::TEXT;

END;
$$;

--
-- This function is used to acknowledge a polled job
--
CREATE OR REPLACE FUNCTION public.pgqueue_poll_job_ack(
    _job_id INT,
    _hmac TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    _string_to_sign TEXT;
BEGIN
    -- Form the string to be signed
    _string_to_sign := 
        _job_id::TEXT 
        || 'ACK';

    -- Update the job status to completed
    UPDATE pgqueue.job_queue
    SET job_status = 'completed', last_at = now()
    WHERE id = _job_id
    AND job_status = 'polled'
    AND encode(
        hmac(
            _string_to_sign::bytea, 
            -- Use decrypted secret if available, else signing_secret
            COALESCE(ds.decrypted_secret, jq.signing_secret),
            'sha256'
        ), 
        'hex'
    ) = _hmac;

    -- If no job found, return false
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- Return true if the job was acknowledged
    RETURN TRUE;

END;
$$;

--
-- Process jobs flagged as polled, failed OR new
-- keeping account for run_at field!
--
CREATE OR REPLACE FUNCTION pgqueue.process_scheduled_jobs()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
    _r RECORD;
    _request_id BIGINT;
    _schema_name TEXT;
    _func_name TEXT;
    _result TEXT;
    _params TEXT;
    _sql TEXT;
BEGIN
    RAISE LOG 'Looking for polled, failed or scheduled jobs';

    -- Look for all jobs either failed or new with a low enough retry_count and run_at
    FOR _r IN (
            SELECT job_id, job_type, url, job_jwt, payload, headers, retry_count FROM pgqueue.job_queue
            WHERE (
                (job_status = 'new') OR
                (job_status = 'polled') OR
                (job_status = 'failed' AND retry_count <= retry_limit)
            ) AND run_at <= NOW()
            FOR UPDATE SKIP LOCKED
    ) LOOP
        RAISE LOG 'Running job_id: %', _r.job_id;

        IF _r.job_type = 'FUNC' THEN
            -- Build schema.function
            IF position('.' IN _r.url) > 0 THEN
                -- split
                _schema_name := split_part(_r.url, '.', 1);
                _func_name := split_part(_r.url, '.', 2);
            ELSE
                -- no schema, default to "public"
                _schema_name := 'public';
                _func_name := _r.url;
            END IF;

            -- Extract and build params for call from payload
            _params := string_agg(
                format('%I := %L', key, value),
                ', '
            ) FROM jsonb_each_text(_r.payload);

            -- Build the final SQL to execute
            _sql := format('SELECT %I.%I(%s)', _schema_name, _func_name, _params);

            -- Execute and store result
            EXECUTE _sql INTO _result;

            -- Set job as done and set _result
            UPDATE pgqueue.job_queue SET
                job_status = 'completed',
                response_content = _result,
                response_status = 200 -- Assuming success
            WHERE job_id = _r.job_id;
        ELSE IF _r.job_type = 'POLL' THEN
            -- means this poll job was not acknowledged in time
            -- log the failure and mark as new again so it can
            -- be picked up by the next poll
            INSERT INTO pgqueue.failed_log
                (job_id, job_run, response_status, response_content)
            VALUES
                (_r.job_id, _r.retry_count+1, 408, 'Poll job not acknowledged in time');

            UPDATE pgqueue.job_queue
                SET job_status = 'new',
                    last_at = NOW(),
                    retry_count = retry_count + 1,
                    response_status = 408,
                    response_content = 'Poll job not acknowledged in time'
                WHERE job_id = _r.job_id;
        ELSE
            -- Call the request_wrapper to process the job
            _request_id := pgqueue.request_wrapper(
                _method := _r.job_type,
                _url := _r.url,
                _jwt := _r.job_jwt,
                _body := _r.payload,
                _headers := _r.headers
            );
            INSERT INTO pgqueue.executed_requests (request_id, job_id)
            VALUES (_request_id, _r.job_id);
        END IF;
    END LOOP;
-- Just in case we have an exception somewhere, log it and fail the job
EXCEPTION
    WHEN OTHERS THEN
        RAISE LOG 'Error processing job_id: %', _r.job_id;
        -- Handle failure and potentially retry or mark as too_many retries
        IF _r.retry_count + 1 > _r.retry_limit THEN
            UPDATE pgqueue.job_queue
                SET job_status = 'too_many',
                    last_at = NOW(),
                    retry_count = retry_count + 1,
                    response_status = 0,
                    response_content = SQLERRM
                WHERE job_id = _r.job_id;
        ELSE
            UPDATE pgqueue.job_queue
                SET job_status = 'failed',
                    last_at = NOW(),
                    retry_count = retry_count + 1,
                    run_at = now() + 
                        INTERVAL '1 second' * 
                        ROUND((POWER(2, retry_count) * (10-(retry_count/1.5)))/2),
                    response_status = 0,
                    response_content = SQLERRM
                WHERE job_id = _r.job_id;
        END IF;

        -- Log the error in our failed_log too
        INSERT INTO pgqueue.failed_log
            (job_id, job_run, response_status, response_content)
        VALUES
            (_r.job_id, _r.retry_count+1, 0, SQLERRM);
END;
$$;

--
-- Helper function to use in pg_cron to process tasks every 10 seconds
--
CREATE OR REPLACE FUNCTION pgqueue.process_job_results_every_ten()
RETURNS void
SECURITY DEFINER
SET search_path TO ''
AS $$
BEGIN
  -- Call process_tasks() with 10 seconds between each call
  PERFORM pgqueue.process_job_results_if_unlocked();
  PERFORM pg_sleep(10);
  PERFORM pgqueue.process_job_results_if_unlocked();
  PERFORM pg_sleep(10);
  PERFORM pgqueue.process_job_results_if_unlocked();
  PERFORM pg_sleep(10);
  PERFORM pgqueue.process_job_results_if_unlocked();
  PERFORM pg_sleep(10);
  PERFORM pgqueue.process_job_results_if_unlocked();
  PERFORM pg_sleep(10);
  PERFORM pgqueue.process_job_results_if_unlocked();
END;
$$ LANGUAGE plpgsql;
