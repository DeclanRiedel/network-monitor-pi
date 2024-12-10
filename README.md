## Key Features
    Per-IP Upload and Download Speeds:

        Uses tshark to estimate per-IP upload/download speeds.
        Logs this data alongside latency and packet loss.

    ISP Throttling/Manipulation Test:

        Uses speedtest-cli to test against multiple public servers to detect performance differences.
        Logs CDN performance using curl against popular endpoints (e.g., Cloudflare, Google, Akamai).
        Records results in a separate SQLite table and JSON file.

## Key Outputs
    Per-IP Data:
        Includes latency, packet loss, upload, and download speeds.
        Exported to per_ip_export.json.

    Overall Network Data:
        Includes ISP-promised speed comparison.
        Exported to overall_export.json.

    Throttling Test Results:
        Tests against CDN and speed test servers.
        Exported to throttling_test.json.

    Database:
        All data is logged in network_data.db.

## cronjob 

0 */3 * * * /script.sh


