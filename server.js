const express = require('express');
const path = require('path');
const https = require('https');
const axios = require('axios');
const httpntlm = require('node-http-ntlm');
const { parse: parseUrl } = require('url');
const fs = require('fs');
const os = require('os');

// Disable certificate validation globally
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

// ---------------------------------------------------------------------------
// Keytar: load the native module in a way that works both during development
// (plain `node server.js`) and when bundled with pkg into a .exe.
//
// When pkg bundles the app the snapshot filesystem has no real disk presence
// for .node files, so we copy keytar.node to a temp directory at startup.
// ---------------------------------------------------------------------------
let keytar;
(function loadKeytar() {
    try {
        if (process.pkg) {
            // Running as a pkg-bundled executable.
            // Look for keytar.node next to the executable first (placed there by the build step),
            // then fall back to extracting from the snapshot into a temp dir.
            const execDir = path.dirname(process.execPath);
            const sibling = path.join(execDir, 'keytar.node');

            if (fs.existsSync(sibling)) {
                keytar = require(sibling);
            } else {
                // Try to extract from pkg snapshot assets
                const tmpPath = path.join(os.tmpdir(), `keytar-${process.pid}.node`);
                const snapshotPath = path.join(__dirname, 'node_modules', 'keytar', 'build', 'Release', 'keytar.node');
                fs.writeFileSync(tmpPath, fs.readFileSync(snapshotPath));
                keytar = require(tmpPath);
            }
        } else {
            keytar = require('keytar');
        }
    } catch (err) {
        console.warn('keytar could not be loaded – proxy credential storage will fall back to HTTPS_PROXY env var.', err.message);
        keytar = null;
    }
})();

// ---------------------------------------------------------------------------
// Open: auto-launch the browser. Optional – gracefully skip if unavailable.
// ---------------------------------------------------------------------------
let openBrowser;
try {
    openBrowser = require('open');
} catch (_) {
    openBrowser = null;
}

const app = express();
const port = process.env.PORT || 3000;

const KEYTAR_SERVICE = 'VersionOneStoryCopier';
const KEYTAR_ACCOUNT = 'ntlm-proxy';

// Middleware to parse JSON bodies
app.use(express.json());

// Serve static files from the current directory
app.use(express.static(path.join(__dirname, '.')));

// ---------------------------------------------------------------------------
// Proxy credential helpers (Windows Credential Manager via keytar)
// ---------------------------------------------------------------------------

/**
 * Retrieve NTLM proxy credentials.
 * Priority: 1) Windows Credential Manager (keytar)  2) HTTPS_PROXY env var
 * Returns { username, password, domain, server } or null.
 */
async function extractProxyCredentials() {
    // 1. Try Windows Credential Manager
    if (keytar) {
        try {
            const stored = await keytar.getPassword(KEYTAR_SERVICE, KEYTAR_ACCOUNT);
            if (stored) {
                const config = JSON.parse(stored);
                if (config && config.username && config.password && config.server) {
                    return {
                        username: config.username,
                        password: config.password,
                        domain: config.domain || '',
                        server: config.server
                    };
                }
            }
        } catch (e) {
            console.warn('Failed to read from Windows Credential Manager:', e.message);
        }
    }

    // 2. Fall back to HTTPS_PROXY environment variable
    const proxyUrl = process.env.HTTPS_PROXY || process.env.https_proxy;
    if (!proxyUrl) return null;

    try {
        const parsedUrl = parseUrl(proxyUrl);
        if (!parsedUrl.auth) return null;

        const [rawUsername, rawPassword] = parsedUrl.auth.split(':');
        if (!rawUsername) return null;

        const username = decodeURIComponent(rawUsername);
        const password = decodeURIComponent(rawPassword || '');

        let domain = '';
        let user = username;
        if (username.includes('\\')) {
            [domain, user] = username.split('\\');
        } else if (username.includes('@')) {
            [user, domain] = username.split('@');
        }

        const server = parsedUrl.host || '';

        return { username: user, password, domain: domain || '', server };
    } catch (e) {
        console.error('Error parsing HTTPS_PROXY env var');
        return null;
    }
}

// ---------------------------------------------------------------------------
// Credential management API endpoints
// ---------------------------------------------------------------------------

/** GET /api/proxy-credentials – return stored proxy config (password redacted) */
app.get('/api/proxy-credentials', async (req, res) => {
    if (!keytar) {
        return res.status(503).json({ error: 'Credential Manager unavailable on this platform.' });
    }
    try {
        const stored = await keytar.getPassword(KEYTAR_SERVICE, KEYTAR_ACCOUNT);
        if (!stored) {
            return res.json({ configured: false });
        }
        const config = JSON.parse(stored);
        res.json({
            configured: true,
            server: config.server || '',
            username: config.username || '',
            domain: config.domain || ''
            // password intentionally omitted
        });
    } catch (e) {
        res.status(500).json({ error: 'Failed to read credentials: ' + e.message });
    }
});

/** POST /api/proxy-credentials – save proxy config to Windows Credential Manager */
app.post('/api/proxy-credentials', async (req, res) => {
    if (!keytar) {
        return res.status(503).json({ error: 'Credential Manager unavailable on this platform.' });
    }
    const { server, username, domain, password } = req.body;
    if (!server || !username || !password) {
        return res.status(400).json({ error: 'server, username and password are required.' });
    }
    try {
        const config = JSON.stringify({ server, username, domain: domain || '', password });
        await keytar.setPassword(KEYTAR_SERVICE, KEYTAR_ACCOUNT, config);
        res.json({ ok: true, message: 'Proxy credentials saved to Windows Credential Manager.' });
    } catch (e) {
        res.status(500).json({ error: 'Failed to save credentials: ' + e.message });
    }
});

/** DELETE /api/proxy-credentials – remove stored proxy credentials */
app.delete('/api/proxy-credentials', async (req, res) => {
    if (!keytar) {
        return res.status(503).json({ error: 'Credential Manager unavailable on this platform.' });
    }
    try {
        const deleted = await keytar.deletePassword(KEYTAR_SERVICE, KEYTAR_ACCOUNT);
        res.json({ ok: deleted, message: deleted ? 'Credentials removed.' : 'No credentials were stored.' });
    } catch (e) {
        res.status(500).json({ error: 'Failed to delete credentials: ' + e.message });
    }
});

// ---------------------------------------------------------------------------
// Main proxy route
// ---------------------------------------------------------------------------
app.all(/^\/api\/v1\/(.*)/, async (req, res) => {
    const v1BaseUrl = req.headers['x-v1-base-url'];
    const v1AuthHeader = req.headers['authorization'];

    const originalUrl = req.originalUrl;
    const apiPrefix = '/api/v1/';
    const apiPathStartIndex = originalUrl.indexOf(apiPrefix);

    let pathAndQuery = '';
    if (apiPathStartIndex !== -1) {
        pathAndQuery = originalUrl.substring(apiPathStartIndex + apiPrefix.length);
    } else {
        console.error('Error parsing API path');
        pathAndQuery = req.params[0] || '';
    }

    const queryIndex = pathAndQuery.indexOf('?');
    let actualApiPath = pathAndQuery;
    let queryParams = null;
    if (queryIndex !== -1) {
        actualApiPath = pathAndQuery.substring(0, queryIndex);
        queryParams = pathAndQuery.substring(queryIndex + 1);
    }

    const baseUrlClean = v1BaseUrl.replace(/\/$/, '');
    const queryString = queryParams ? '?' + queryParams : '';
    const targetUrl = `${baseUrlClean}/${actualApiPath}${queryString}`;

    let apiResponse;

    try {
        const ntlmCredentials = await extractProxyCredentials();

        if (ntlmCredentials) {
            const ntlmOptions = {
                url: targetUrl,
                username: ntlmCredentials.username,
                password: ntlmCredentials.password,
                domain: ntlmCredentials.domain,
                workstation: '',
                headers: {
                    'Accept': 'application/json, text/plain, */*',
                    ...(req.headers.cookie && { 'Cookie': req.headers.cookie }),
                    ...(req.headers['user-agent'] && { 'User-Agent': req.headers['user-agent'] }),
                    ...(req.headers.referer && { 'Referer': req.headers.referer }),
                    ...(req.headers['x-requested-with'] && { 'X-Requested-With': req.headers['x-requested-with'] }),
                    ...(req.headers['content-type'] && { 'Content-Type': req.headers['content-type'] })
                },
                ...(req.body && Object.keys(req.body).length > 0 && {
                    body: JSON.stringify(req.body)
                }),
                timeout: 30000,
                allowRedirects: false
            };

            const method = req.method.toLowerCase();

            const makeNtlmRequest = () => new Promise((resolve, reject) => {
                httpntlm[method](ntlmOptions, (err, ntlmRes) => {
                    if (err) {
                        console.error('NTLM request failed');
                        const errorObj = new Error(err.message || 'node-http-ntlm request failed');
                        errorObj.code = err.code;
                        if (ntlmRes) {
                            errorObj.response = {
                                status: ntlmRes.statusCode,
                                headers: ntlmRes.headers,
                                data: ntlmRes.body
                            };
                        }
                        return reject(errorObj);
                    }
                    resolve({
                        status: ntlmRes.statusCode,
                        headers: ntlmRes.headers,
                        data: ntlmRes.body
                    });
                });
            });

            apiResponse = await makeNtlmRequest();

        } else {
            const directAxiosConfig = {
                method: req.method,
                url: targetUrl,
                headers: {
                    'Authorization': v1AuthHeader,
                    'Accept': 'application/json',
                    ...(req.headers['content-type'] && { 'Content-Type': req.headers['content-type'] }),
                },
                ...(req.body && Object.keys(req.body).length > 0 && { data: req.body }),
                validateStatus: function (status) {
                    return status >= 200 && status < 600;
                },
                timeout: 30000,
                maxRedirects: 0,
                httpsAgent: new https.Agent({
                    rejectUnauthorized: false,
                    keepAlive: true,
                })
            };

            apiResponse = await axios(directAxiosConfig);
        }

        if (apiResponse.headers) {
            Object.entries(apiResponse.headers).forEach(([key, value]) => {
                if (key.toLowerCase() !== 'transfer-encoding') {
                    res.setHeader(key, value);
                }
            });
        }
        res.status(apiResponse.status).send(apiResponse.data);

    } catch (error) {
        console.error(`API Error: ${error.message}`);
        if (error.response) {
            res.status(error.response.status).json({
                error: `API Error: ${error.response.status}`,
                message: error.message,
                details: error.response.data
            });
        } else {
            res.status(500).json({
                error: 'Connection Error',
                message: error.message,
                code: error.code
            });
        }
    }
});

// Serve index.html for root
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

// ---------------------------------------------------------------------------
// Start server and (optionally) open browser automatically
// ---------------------------------------------------------------------------
app.listen(port, () => {
    const url = `http://localhost:${port}`;
    console.log(`Server running at ${url}`);

    if (openBrowser) {
        openBrowser(url).catch(() => {
            // Silently ignore if we cannot open a browser (e.g. headless environment)
        });
    }
});
