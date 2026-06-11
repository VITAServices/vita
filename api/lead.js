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

const NOTIFY_EMAIL = 'Lorena@vitasoinsetservices.com';
const NOTIFY_PHONE = '+15149176167';
const FROM_EMAIL = process.env.NOTIFY_FROM_EMAIL || 'VITA Website <onboarding@resend.dev>';

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

    const { source, firstName, lastName, email, phone, details } = req.body || {};

    if (!source || !SOURCES[source] || !firstName || !lastName || !email || !phone) {
        return res.status(400).json({ ok: false, error: 'invalid_payload' });
    }

    const lead = {
        source,
        first_name: String(firstName).trim(),
        last_name: String(lastName).trim(),
        email: String(email).trim(),
        phone: String(phone).trim(),
        details: details && typeof details === 'object' ? details : {},
    };

    const { data: inserted, error: dbError } = await supabase
        .from('leads')
        .insert(lead)
        .select()
        .single();

    if (dbError) {
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
