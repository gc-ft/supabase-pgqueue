
# PGQueue: PostgreSQL-Based Job Queue and Webhook System for Supabase

**PGQueue** is a sophisticated job queue and webhook processing system built on top of PostgreSQL. It was built specifically with Supabase in mind and enables efficient scheduling, execution, and management of asynchronous jobs directly within the database. PGQueue supports running internal PostgreSQL functions, making HTTP requests, handling retries, managing authorization with JWTs, and signing requests with HMAC, all while providing robust logging and error handling mechanisms.

It can be used to replace `supabase_functions.http_request()` for webhooks, offering a more robust, and feature rich implementation.

## Copyright
   Copyright 2024 Fabian Thylmann

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

## Attribution / Thanks

The idea behind PGQueue comes from [supa_queue](https://github.com/mansueli/supa_queue) by Rodrigo Mansueli.


## Table of Contents

1. [Features Overview](#features)
2. [Installation](#installation)
3. [Configuration](#configuration)
4. [Usage](#usage)
   - [Job Queue Structure](#job-queue-structure)
   - [Job Lifecycle](#job-lifecycle)
   - [Request Signing](#request-signing)
   - [Webhook Integration](#webhook-integration)
5. [Job Status and Error Handling](#job-status-and-error-handling)
6. [Examples](#examples)
7. [Contributing](#contributing)
8. [License](#license)

## Features Overview

- **Flexible Job & Retry Scheduling**: Schedule jobs to run at specific times, including delayed execution for handling 429 errors and implementing exponential backoff strategies.
- **Jobs creating Jobs**: A Job can reply with a special payload to schedule a new job.
- **Internal Function Execution**: Use the job queue to execute PostgreSQL functions instead of URLs with dynamic parameter handling.
- **HTTP Request Handling**: Queue and execute HTTP requests with full support for custom headers, payloads, and different HTTP methods (`GET`, `POST`, `DELETE`).
- **JWT Management**: Support for using JWT tokens stored directly with the job queue entry, in the vault (for service_role key) or dynamically retrieved from the current session.
- **Request Signing**: Built-in HMAC signing with configurable algorithms and encoding styles to secure your webhooks and API calls.
- **Webhook Triggers**: Easily create webhook triggers for database events using the `pgqueue.trigger_webhook` function.
- **Comprehensive Error Handling**: Automatic retries for failed jobs, detailed logging of responses, and flexible handling of various HTTP status codes.
- **Logging and Auditing**: Keep track of job execution, including detailed logs of failed attempts for troubleshooting and auditing purposes.

## Installation

### Prerequisites

1. Either: 
- **Supabase** with `pg_net` and `pg_cron` (will be enabled by sql file)

2. Or possibly (untested):
- **PostgreSQL 13+** with PL/pgSQL enabled.
- **pg_net** for making HTTP requests from within PostgreSQL.
- **pg_cron** for setting up cron jobs to run job handling

### Setup (Supabase)

1. Ensure that the required PostgreSQL extensions (`pg_cron`, `pg_net`) are installed and enabled in Supabase.

2. Run the SQL setup script present in the migrations directory to create the necessary database schema, types, and functions:

   ```sql
   psql -d your_database -f ./migrations/pgqueue-v1.sql
   ```

    Or paste it into the SQL Editor and Run it.

3. To add cron entries that run the needed functions use the below SQL in the SQL Editor:

    ```
    -- Look for jobs each minute
    SELECT cron.schedule(
        'pgqueue.run_scheduled_jobs',
        '* * * * *',
        $$ SELECT pgqueue.run_scheduled_jobs(); $$
    );
    -- Schedule process jobs 3 times per minute:
    SELECT cron.schedule(
        'pgqueue.process_tasks_subminute',
        '* * * * *',
        $$ SELECT pgqueue.process_tasks_subminute(); $$
    );
    ```

## Configuration

### Vault Setup

Inside the Supabase `vault` schema, in table `secrets` set the following variables:

- **consumer_edge_base**
This should be set to the base url of your Supabase Edge Functions, ending *without* `/`. eg.: `https://<reference id>.supabase.co/functions/v1`
- **service_role**
Set this to your Supabase service_role key, if you want to use service_role
keys for some jobs executing edge functions.
- _**signing keys**_:
If you want to use the Signature Header generation feature of `pgqueue` and use `signing_vault` setting in a job, set any `signing_vault` variables to the corresponding secret for the signature.


## Usage

### Job Queue Structure

The `pgqueue.job_queue` table is the core structure where jobs are queued and managed. It includes the following key fields:

- **job_owner** _(optional)_: Arbitrary identifier for the owner of the job.
- **run_at** _(default: now())_: Timestamp when the job should first run, supporting delayed execution.
- **job_type** _(default: `POST`)_: Specifies the type of job (`GET`, `POST`, `DELETE`, `FUNC`).
- **url**:
    - Supabase Edge Functions: The name prefixed with a leading `/`, eg.: `/hello-world`. (The system expects at least `consumer_edge_base` to be set in the Supabase Vault and also `service_role` if no `job_jwt` is provided (see below)!)
    - HTTP Requests: The full target URL, eg.: `https://domain.com/path/to/url?query=value`
    - `FUNC` type jobs: Fully qualified Postgresql function name, if no schema is included, schema `public` is expected, eg.: `some_function` or `schema.some_function`
- **payload**: Payload in JSON format for edge functions or http requests, or a JSON representing function parameters to call the Postgresql function with.
- **headers**: Custom HTTP headers to be set for the job in JSON format. `Content-type` header is automatically set to `application/json` and for edge functions the `Authorization` header is set to what is expected based on the `job_jwt` setting (see below). Use `signing_*` fields to dynamically set a signature header too.
- **job_jwt**: JWT token for authorization, can be set to `'from_session'` for session-based tokens.
- **signing_secret / signing_vault**: Securely manage HMAC signing secrets. See [Request Signing](#request-signing) below.
- **retry_limit** _(default: 10)_: Number of retry attempts for failed jobs.

### Job Lifecycle

Jobs go through various statuses from `new` to `completed`, with automatic handling of retries and exponential backoff for rate limiting (`429` status codes). See [Job Status and Error Handling](#job-status-and-error-handling).

### Request Signing

In certain scenarios, it is necessary to add a signature to a request to ensure its authenticity and integrity when it reaches the target server. PGQueue provides a built-in mechanism for HMAC (Hash-based Message Authentication Code) signing of requests. The signing process is flexible and can be customized based on the following fields in the `pgqueue.job_queue` table:

- **signing_secret (BYTEA)**: This field stores the direct secret key used for generating the HMAC signature. The secret must be stored as a `BYTEA` value in the `pgqueue.job_queue` table. This secret can be directly referenced during the signing process.

- **signing_vault (TEXT)**: Instead of directly storing the signing secret in the `signing_secret` field, you can store a reference to a vault entry in this field. When this field is set, PGQueue will retrieve the secret from the specified vault entry and convert it to `BYTEA` automatically before using it to generate the HMAC signature.

- **signing_header (TEXT)**: This field specifies the HTTP header name under which the generated HMAC signature will be sent in the request. By default, this field is set to `X-HMAC-Signature`, but it can be customized as needed.

- **signing_style (enum)**: The signing style determines how the signature is formatted. It can take two values:
  - `HMAC`: The generated signature is sent as-is in the specified header.
  - `HMAC_WITH_PREFIX`: The signature is prefixed by the algorithm used to generate it (e.g., `sha256=<signature>`).

- **signing_alg (enum)**: This field specifies the hashing algorithm used for the HMAC signature. PGQueue supports a variety of algorithms, including `md5`, `sha1`, `sha224`, `sha256`, `sha384`, and `sha512`. The default algorithm is `sha256`.

- **signing_enc (enum)**: This field controls the encoding of the final signature. It can be set to either `hex` or `base64`, with `hex` being the default.

The signature is generated automatically when a job is inserted into the `pgqueue.job_queue` table via a trigger. This trigger computes the HMAC signature by converting the payload to TEXT and generating the HMAC for it using the `secret` and adds it to `headers` using the specified header field name.
_NOTE:_ Modifying the the payload later does NOT re-trigger setting a new signature header!

### Webhook Integration

PGQueue makes it easy to integrate webhook functionality into your PostgreSQL database. With the `pgqueue.trigger_webhook` function, you can create database triggers that automatically enqueue webhook calls whenever certain events occur within your database.

Use the `pgqueue.trigger_webhook` function as the trigger function in `CREATE TRIGGER` sql commands using the parameters below.

#### Function Parameters:

- **_url (TEXT)**: The URL to which the webhook should be sent. This is the only required parameter. It conforms to the same rules as the url field in the job_queue table! (See [above](#job-queue-structure))

- **_headers (JSONB)** (optional): Optional JSON object containing additional headers to be included in the webhook request. Common headers such as `Content-Type` and `Authorization` can be set here.

- **_jwt (TEXT)** (optional): JWT token to be used for authorization in case of an Supabase Edge Function. If set to `'from_session'`, the function will copy the `Authorization` header from the current PostgREST session.

- **_signing_secret (BYTEA)** (optional): Optional secret key for signing the webhook request. If provided, an HMAC signature will be generated. (See [Request Signing](#request-signing))

- **_signing_vault (TEXT)** (optional): Optional reference to a vault entry containing the signing secret. If provided, the secret will be retrieved from the vault and used to sign the request. (See [Request Signing](#request-signing))

- **_signing_header (TEXT)** (optional): The name of the header that will contain the HMAC signature. Defaults to `X-HMAC-Signature`. (See [Request Signing](#request-signing))

- **_signing_style (enum)** (optional): The style of the HMAC signature, either `HMAC` or `HMAC_WITH_PREFIX`. (See [Request Signing](#request-signing))

- **_signing_alg (enum)** (optional, default: `sha256`): The algorithm used for the HMAC signature. (See [Request Signing](#request-signing))

- **_signing_enc (enum)** (optional, default `hex`): The encoding of the final signature, either `hex` or `base64`. (See [Request Signing](#request-signing))

#### Generated Payload

The function will build a `payload` JSON for the trigger automatically, using the following format:

```json
{
    "type": "INSERT" | "UPDATE" | "DELETE",
    "table": <table name>,
    "schema": <table schema name>,
    "old_record": <RECORD as JSON> | null,
    "record": <RECORD as JSON> | null,
}
```


#### Example 1:

```sql
CREATE TRIGGER after_insert_trigger
AFTER INSERT ON my_table
FOR EACH ROW
EXECUTE FUNCTION pgqueue.trigger_webhook(
    _url := 'https://webhook.site/your-webhook-url',
    _headers := '{"X-Webhook-Event": "new_record"}'::jsonb,
    _signing_secret := 'my-secret-key'::bytea
);
```

In this example, whenever a new row is inserted into `my_table`, a webhook will be sent to `https://webhook.site/your-webhook-url` with the event details. The webhook request will include the customer HTTP Header `X-Webhook-Event` and a generated HMAC signature (in HTTP Header `X-HMAC-Signature`) based on the provided secret key and the trigger payload.

#### Example 2:

```sql
CREATE TRIGGER after_update_trigger
AFTER UPDATE ON my_table
FOR EACH ROW
EXECUTE FUNCTION pgqueue.trigger_webhook(
    _url := '/my_edge_function'
);
```

In this example, whenever a row is updated in `my_table`, a webhook is sent to the Supabase Edge Function called `my_edge_function`. Since no `_jwt` is provided, PGQueue will get the `service_role` key from Supabase Vault and use that key in the `Authorization` header. No HMAC Signature is generated for the request.


### Job Status and Error Handling

PGQueue provides a comprehensive system for managing job statuses and handling errors to ensure reliable and consistent processing of tasks.

#### Job Statuses

Each job in the `pgqueue.job_queue` table goes through various statuses during its lifecycle. These statuses help track the job's progress and determine the appropriate actions based on the job's outcome.

- **new**: The job has been newly created and is ready for processing. This is the initial status assigned to all jobs upon creation.

- **failed**: The job encountered an error during processing but will be retried later. The retry behavior is controlled by the `retry_limit` field, which specifies how many times the job can be retried before it is marked as `too_many`.

- **processing**: The job is currently being processed. This status is set when the job begins execution, indicating that the system is actively working on it.

- **completed**: The job has successfully completed its task. This status is assigned when the job receives a 2xx HTTP status code, or when specific conditions indicate that the job has been completed successfully.

- **redirected**: The job has completed with a 201 HTTP status code, indicating a new job to process. The response fields, are set and a new job is generated. This status should be treated as **completed** and is just present to inform that a new job was created due to this job.

- **server_error**: The job failed due to a 500-level server error. Jobs with this status will not be retried, as the error is assumed to be a non-recoverable server issue.

- **too_many**: The job has been retried the maximum number of times allowed by the `retry_limit` field and will no longer be processed. This status indicates that the system has exhausted all attempts to successfully execute the job.

- **other**: The job encountered an unexpected status code that does not fall into the typical categories of success, redirection, or server error. This status is used for handling edge cases where the response is outside the anticipated range.

#### Error Handling and Retries

PGQueue is designed to handle errors gracefully and to automatically retry jobs when appropriate. The following scenarios describe how errors are managed:

- **2xx Status Codes**: The job is marked as `completed` when a successful 2xx response is received from the target URL. This indicates that the job has fulfilled its purpose.

- **429 Status Codes (Rate Limiting)**: When a job encounters a 429 status code, which indicates that the rate limit has been exceeded, the job is rescheduled based on the `Retry-After` header. If the `Retry-After` header is not present, the job is rescheduled to run in 10 minutes by default.

- **4xx Status Codes**: If the job receives a 4xx status code (e.g., 400 Bad Request, 404 Not Found), it will typically be retried unless the response includes an `x-job-finished` header. If the `x-job-finished` header is present, the job is marked as `completed`, even though the status code indicates a client error.

- **5xx Status Codes**: Jobs that receive a 500-level status code are marked as `server_error` and will not be retried. This indicates a server-side issue that is not expected to be resolved by retrying the job.

- **Exponential Backoff for Retries**: PGQueue uses an exponential backoff strategy for retrying failed jobs. This means that the wait time between retries increases exponentially, helping to avoid overwhelming the target system and providing more time for transient issues to resolve.

#### Logging and Auditing

PGQueue maintains a detailed log of all job attempts, including successful completions and failures. The logging system is designed to provide full traceability and auditing of job execution, ensuring that you can diagnose and understand the behavior of each job.

The `pgqueue.job_queue` table has the following fields for each job which is updated as it is executed: 

- **response_status**: This field records the HTTP status code received from the most recent attempt to execute the job. It provides a quick reference to the outcome of the last attempt.

- **response_content**: The raw reply body of the response from the job is stored in this field. This can include error messages, success confirmations, or any other relevant data returned by the server. 

- **response_headers**: Any HTTP headers returned in the response are stored here. These headers can provide additional context, such as rate-limiting information (`Retry-After`) or custom headers that indicate specific processing outcomes (`x-job-finished`).

PGQueue also maintains a separate log of failed attempts in the `pgqueue.failed_log` table, particularly those that result in 4xx errors or complete failures (with a response status of 0). This failure log keeps all failed retries information and not just the last one.


## Examples

### Queueing a Simple HTTP POST Job
The below creates a simple job that posts a JSON payload to `https://example.com/api` including a custom header. The job is executed the first time right after inserting it into the table.

```sql
INSERT INTO pgqueue.job_queue (
    job_type, url, payload, headers
) VALUES (
    'POST',
    'https://example.com/api',
    '{"data": "value"}'::jsonb,
    '{"X-Custom-Header": "value"}'::jsonb,
);
```

### Creating a Webhook Trigger
The below creates a trigger that executes each time a row is inserted into my_table. The trigger calls a URL and creates an HMAC signature using a secret it finds in the Supabase Vault entry `hmac_secret`.

```sql
CREATE TRIGGER after_insert_trigger
AFTER INSERT ON my_table
FOR EACH ROW
EXECUTE FUNCTION pgqueue.trigger_webhook(
    _url := 'https://webhook.site/your-webhook-url',
    _signing_vault := 'hmac_secret'
);
```

## Contributing

We welcome contributions! Please fork the repository, create a new branch, and submit a pull request with your changes. Make sure to include changes for this README and follow the existing code style.

## License

This project is licensed under the Apache 2.0 License - see the [LICENSE](LICENSE) file for details.
