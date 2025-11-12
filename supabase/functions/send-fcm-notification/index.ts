import { serve } from "https://deno.land/std@0.168.0/http/server.ts"

const FIREBASE_SERVER_KEY = Deno.env.get("FIREBASE_SERVER_KEY")
const FIREBASE_SERVICE_ACCOUNT = Deno.env.get("FIREBASE_SERVICE_ACCOUNT")

function base64UrlEncode(input: Uint8Array | string) {
    let bytes: Uint8Array
    if (typeof input === "string") bytes = new TextEncoder().encode(input)
    else bytes = input
    let str = btoa(String.fromCharCode(...bytes))
    return str.replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_")
}

function pemToArrayBuffer(pem: string) {
    const b64 = pem
        .replace(/-----BEGIN PRIVATE KEY-----/, "")
        .replace(/-----END PRIVATE KEY-----/, "")
        .replace(/\s+/g, "")
    const binary = atob(b64)
    const len = binary.length
    const bytes = new Uint8Array(len)
    for (let i = 0; i < len; i++) bytes[i] = binary.charCodeAt(i)
    return bytes.buffer
}

async function createAccessTokenFromServiceAccount(saJson: string) {
    const sa = JSON.parse(saJson)
    const client_email = sa.client_email
    const private_key = sa.private_key
    const project_id = sa.project_id
    const now = Math.floor(Date.now() / 1000)
    const header = { alg: "RS256", typ: "JWT" }
    const scope = "https://www.googleapis.com/auth/firebase.messaging"
    const payload = {
        iss: client_email,
        scope,
        aud: "https://oauth2.googleapis.com/token",
        exp: now + 3600,
        iat: now,
    }

    const encodedHeader = base64UrlEncode(JSON.stringify(header))
    const encodedPayload = base64UrlEncode(JSON.stringify(payload))
    const toSign = `${encodedHeader}.${encodedPayload}`

    const keyData = pemToArrayBuffer(private_key)
    const cryptoKey = await crypto.subtle.importKey(
        "pkcs8",
        keyData,
        {
            name: "RSASSA-PKCS1-v1_5",
            hash: "SHA-256",
        },
        false,
        ["sign"]
    )

    const signature = await crypto.subtle.sign(
        "RSASSA-PKCS1-v1_5",
        cryptoKey,
        new TextEncoder().encode(toSign)
    )
    const encodedSignature = base64UrlEncode(new Uint8Array(signature))
    const jwt = `${toSign}.${encodedSignature}`

    const form = new URLSearchParams()
    form.append("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer")
    form.append("assertion", jwt)

    const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: form.toString(),
    })

    if (!tokenRes.ok) {
        const text = await tokenRes.text()
        throw new Error(
            `Failed to obtain access token: ${tokenRes.status} ${text}`
        )
    }

    const tokenJson = await tokenRes.json()
    return { access_token: tokenJson.access_token, project_id }
}

serve(async req => {
    try {
        const payload = await req.json()
        const { token, title, body, data, tenant_url, tenant_anon_key } =
            payload

        if (!title || !body) {
            return new Response(
                JSON.stringify({
                    error: "Missing required parameters: title/body",
                }),
                { status: 400, headers: { "Content-Type": "application/json" } }
            )
        }

        if (!FIREBASE_SERVER_KEY && !FIREBASE_SERVICE_ACCOUNT) {
            return new Response(
                JSON.stringify({
                    error: "Server not configured: FIREBASE_SERVER_KEY or FIREBASE_SERVICE_ACCOUNT missing",
                }),
                { status: 500, headers: { "Content-Type": "application/json" } }
            )
        }

        // Helper to send to a single token.
        // Use FCM HTTP v1 with service account if available, otherwise fallback to legacy key.
        let v1AccessToken: string | null = null
        let v1ProjectId: string | null = null
        if (FIREBASE_SERVICE_ACCOUNT) {
            const tok = await createAccessTokenFromServiceAccount(
                FIREBASE_SERVICE_ACCOUNT
            )
            v1AccessToken = tok.access_token
            v1ProjectId = tok.project_id
        }

        const sendToToken = async (destToken: string) => {
            if (v1AccessToken && v1ProjectId) {
                const v1Body = {
                    message: {
                        token: destToken,
                        notification: { title, body },
                        data: data || {},
                        android: { priority: "HIGH" },
                        apns: { headers: { "apns-priority": "10" } },
                    },
                }
                const url = `https://fcm.googleapis.com/v1/projects/${v1ProjectId}/messages:send`
                const response = await fetch(url, {
                    method: "POST",
                    headers: {
                        "Content-Type": "application/json",
                        Authorization: `Bearer ${v1AccessToken}`,
                    },
                    body: JSON.stringify(v1Body),
                })
                const result = await response.json()
                if (!response.ok)
                    throw new Error(`FCM v1 error: ${JSON.stringify(result)}`)
                return result
            }

            if (!FIREBASE_SERVER_KEY)
                throw new Error("No Firebase server key configured")
            const fcmMessage = {
                to: destToken,
                notification: { title, body },
                data: data || {},
                priority: "high",
                content_available: true,
            }

            const response = await fetch(
                "https://fcm.googleapis.com/fcm/send",
                {
                    method: "POST",
                    headers: {
                        "Content-Type": "application/json",
                        Authorization: `key=${FIREBASE_SERVER_KEY}`,
                    },
                    body: JSON.stringify(fcmMessage),
                }
            )

            const result = await response.json()
            if (!response.ok) {
                throw new Error(`FCM API error: ${JSON.stringify(result)}`)
            }
            return result
        }

        // If a single token provided, send to it and return result
        if (token) {
            const result = await sendToToken(token)
            return new Response(
                JSON.stringify({ success: true, results: [result] }),
                { headers: { "Content-Type": "application/json" } }
            )
        }

        // If tenant credentials provided, fetch device tokens from tenant project and send to each
        if (tenant_url && tenant_anon_key) {
            // Fetch device tokens from Supabase REST API
            const url =
                tenant_url.replace(/\/$/, "") +
                "/rest/v1/device_tokens?select=fcm_token"
            const res = await fetch(url, {
                method: "GET",
                headers: {
                    apikey: tenant_anon_key,
                    Authorization: `Bearer ${tenant_anon_key}`,
                    Accept: "application/json",
                },
            })

            if (!res.ok) {
                const errBody = await res.text()
                throw new Error(
                    `Failed to fetch device tokens from tenant: ${res.status} ${errBody}`
                )
            }

            const tokens = await res.json()
            if (!Array.isArray(tokens) || tokens.length === 0) {
                return new Response(
                    JSON.stringify({
                        success: true,
                        results: [],
                        note: "No device tokens found",
                    }),
                    { headers: { "Content-Type": "application/json" } }
                )
            }

            const results: any[] = []
            for (const t of tokens) {
                const dest = t.fcm_token || t.token || null
                if (!dest) continue
                try {
                    const r = await sendToToken(dest)
                    results.push({ token: dest, ok: true, result: r })
                } catch (err) {
                    const msg = err instanceof Error ? err.message : String(err)
                    results.push({ token: dest, ok: false, error: msg })
                }
            }

            return new Response(JSON.stringify({ success: true, results }), {
                headers: { "Content-Type": "application/json" },
            })
        }

        return new Response(
            JSON.stringify({
                error: "Missing target: provide token or tenant_url+tenant_anon_key",
            }),
            { status: 400, headers: { "Content-Type": "application/json" } }
        )
    } catch (error) {
        const msg = error instanceof Error ? error.message : String(error)
        return new Response(JSON.stringify({ error: msg }), {
            status: 500,
            headers: { "Content-Type": "application/json" },
        })
    }
})
