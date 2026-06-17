import { createClient } from '@supabase/supabase-js';
import { Resend } from 'resend';
import twilio from 'twilio';

const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);
const resend = new Resend(process.env.RESEND_API_KEY);
// Twilio client is created on demand so missing credentials don't crash the module
function getTwilioClient() {
    const sid = process.env.TWILIO_ACCOUNT_SID;
    const token = process.env.TWILIO_AUTH_TOKEN;
    if (!sid || !token) return null;
    return twilio(sid, token);
}

const NOTIFY_EMAIL = 'info@vitasoinsetservices.com';
const NOTIFY_PHONE = '+14388393838';
const FROM_EMAIL = process.env.NOTIFY_FROM_EMAIL || 'VITA Website <onboarding@resend.dev>';

// Only accept browser submissions coming from our own site. Requests with no
// Origin header (e.g. server-to-server, curl) are allowed through so the form
// keeps working in edge cases; requests with a foreign Origin are rejected.
const ALLOWED_ORIGINS = new Set([
    'https://www.vitasoinsetservices.com',
    'https://vitasoinsetservices.com',
    'https://www.vitasoinsetservices.ca',
    'https://vitasoinsetservices.ca',
]);

// Maximum accepted length per field — anything longer is almost certainly
// abuse, and caps keep the database, emails, and SMS sane.
const MAX_LEN = {
    name: 80,
    email: 254,
    phone: 40,
    detailKey: 80,
    detailValue: 2000,
};
const MAX_DETAIL_ENTRIES = 20;

// Minimum time (ms) a real person needs to fill the form. Submissions faster
// than this are treated as bots when the client reports elapsed time.
const MIN_FILL_MS = 2000;

function cap(value, max) {
    return String(value == null ? '' : value).trim().slice(0, max);
}

function sanitizeDetails(details) {
    if (!details || typeof details !== 'object' || Array.isArray(details)) return {};
    const out = {};
    let count = 0;
    for (const [key, value] of Object.entries(details)) {
        if (count >= MAX_DETAIL_ENTRIES) break;
        if (value == null || value === '') continue;
        out[cap(key, MAX_LEN.detailKey)] = cap(value, MAX_LEN.detailValue);
        count++;
    }
    return out;
}

const SOURCES = {
    care_request: {
        label: 'New Care Request',
        emailSubject: (name) => `New Care Request - ${name}`,
        smsLine: (name, phone) => `VITA: New care request from ${name}, ${phone}. Check your email for details.`,
    },
    job_application: {
        label: 'New Job Application',
        emailSubject: (name) => `New Job Application - ${name}`,
        smsLine: (name, phone) => `VITA: New job application from ${name}, ${phone}. Check your email for details.`,
    },
};

function buildEmailBody(source, lead) {
    const lines = [
        SOURCES[source].label,
        '=================================='.slice(0, 34),
        '',
        `Name:    ${lead.first_name} ${lead.last_name}`,
        `Email:   ${lead.email}`,
        `Phone:   ${lead.phone}`,
    ];
    Object.entries(lead.details || {}).forEach(([key, value]) => {
        if (value) lines.push(`${key}: ${value}`);
    });
    lines.push('', `Submitted: ${new Date().toISOString()}`);
    lines.push('', 'This lead has been saved to the VITA leads database.');
    return lines.join('\n');
}

export default async function handler(req, res) {
    if (req.method !== 'POST') {
        res.setHeader('Allow', 'POST');
        return res.status(405).json({ ok: false, error: 'method_not_allowed' });
    }

    // Reject cross-origin browser submissions (CSRF / off-site abuse).
    const origin = req.headers.origin;
    if (origin && !ALLOWED_ORIGINS.has(origin)) {
        return res.status(403).json({ ok: false, error: 'forbidden_origin' });
    }

    const { source, firstName, lastName, email, phone, details, hp, elapsedMs } = req.body || {};

    // Honeypot: real users never fill this hidden field, and real users take
    // longer than MIN_FILL_MS. Respond 200 so bots think they succeeded, but
    // skip saving and notifying.
    const tooFast = typeof elapsedMs === 'number' && elapsedMs >= 0 && elapsedMs < MIN_FILL_MS;
    if ((typeof hp === 'string' && hp.trim() !== '') || tooFast) {
        return res.status(200).json({ ok: true, id: null });
    }

    if (!source || !SOURCES[source] || !firstName || !lastName || !email || !phone) {
        return res.status(400).json({ ok: false, error: 'invalid_payload' });
    }

    const lead = {
        source,
        first_name: cap(firstName, MAX_LEN.name),
        last_name: cap(lastName, MAX_LEN.name),
        email: cap(email, MAX_LEN.email),
        phone: cap(phone, MAX_LEN.phone),
        details: sanitizeDetails(details),
    };

    // A basic shape check on the email so the table stays clean.
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(lead.email) || !lead.first_name || !lead.last_name || !lead.phone) {
        return res.status(400).json({ ok: false, error: 'invalid_payload' });
    }

    const { data: inserted, error: dbError } = await supabase
        .from('leads')
        .insert(lead)
        .select()
        .single();

    if (dbError) {
        console.error('Supabase insert error:', JSON.stringify(dbError));
        return res.status(500).json({ ok: false, error: 'db_insert_failed' });
    }

    const fullName = `${lead.first_name} ${lead.last_name}`;
    const notif = SOURCES[source];
    let notifiedEmail = false;
    let notifiedSms = false;

    try {
        await resend.emails.send({
            from: FROM_EMAIL,
            to: NOTIFY_EMAIL,
            subject: notif.emailSubject(fullName),
            text: buildEmailBody(source, lead),
        });
        notifiedEmail = true;
    } catch (err) {
        console.error('Resend email failed:', err);
    }

    const twilioPhone = process.env.TWILIO_PHONE_NUMBER;
    if (twilioPhone) {
        try {
            const twilioClient = getTwilioClient();
            if (twilioClient) {
                await twilioClient.messages.create({
                    from: twilioPhone,
                    to: NOTIFY_PHONE,
                    body: notif.smsLine(fullName, lead.phone),
                });
                notifiedSms = true;
            }
        } catch (err) {
            console.error('Twilio SMS failed:', err);
        }
    }

    if (notifiedEmail || notifiedSms) {
        await supabase
            .from('leads')
            .update({ notified_email: notifiedEmail, notified_sms: notifiedSms })
            .eq('id', inserted.id);
    }

    return res.status(200).json({ ok: true, id: inserted.id });
}
