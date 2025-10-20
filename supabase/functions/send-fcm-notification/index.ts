import { serve } from "https://deno.land/std@0.168.0/http/server.ts"

const FIREBASE_SERVER_KEY = Deno.env.get('FIREBASE_SERVER_KEY')

serve(async (req) => {
  try {
    const { token, title, body, data } = await req.json()

    if (!token || !title || !body) {
      return new Response(
        JSON.stringify({ error: 'Missing required parameters' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const fcmMessage = {
      to: token,
      notification: {
        title,
        body,
      },
      data: data || {},
      priority: 'high',
      content_available: true,
    }

    const response = await fetch('https://fcm.googleapis.com/fcm/send', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `key=${FIREBASE_SERVER_KEY}`,
      },
      body: JSON.stringify(fcmMessage),
    })

    const result = await response.json()

    if (!response.ok) {
      throw new Error(`FCM API error: ${JSON.stringify(result)}`)
    }

    return new Response(
      JSON.stringify({ success: true, result }),
      { headers: { 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}) 