# 🔧 Friday Jarvis Setup Guide

## 🚨 Current Issue: LiveKit Connection Failed

The error `401 Unauthorized` indicates missing or incorrect LiveKit credentials. Follow these steps to fix it:

## 📋 Step-by-Step Setup

### 1. **Get LiveKit Credentials**

1. **Sign up for LiveKit Cloud**:
   - Go to [https://cloud.livekit.io/](https://cloud.livekit.io/)
   - Create a free account
   - Create a new project

2. **Get Your Credentials**:
   - In your LiveKit project dashboard
   - Go to "API Keys" section
   - Copy your:
     - **API Key**
     - **API Secret**
     - **URL** (should be something like `wss://your-project.livekit.cloud`)

### 2. **Configure Environment Variables**

Edit your `.env` file with your actual credentials:

```env
# LiveKit Credentials
LIVEKIT_URL=wss://your-project.livekit.cloud
LIVEKIT_API_KEY=your_actual_api_key_here
LIVEKIT_API_SECRET=your_actual_api_secret_here

# Gmail Credentials (for email functionality)
GMAIL_USER=your-email@gmail.com
GMAIL_APP_PASSWORD=your-gmail-app-password
```

### 3. **Test the Connection**

Run the agent to test:
```bash
python agent.py
```

You should see:
```
✅ LiveKit credentials loaded successfully!
```

## 🔍 Troubleshooting

### If you still get 401 errors:

1. **Check your credentials**:
   - Ensure API Key and Secret are correct
   - Make sure there are no extra spaces
   - Verify the URL format

2. **Verify LiveKit project**:
   - Ensure your LiveKit project is active
   - Check if you have sufficient credits/quota

3. **Network issues**:
   - Check your internet connection
   - Try from a different network if possible

### Common Issues:

- **"Invalid API Key"**: Double-check your API key spelling
- **"Project not found"**: Verify your LiveKit project URL
- **"Quota exceeded"**: Upgrade your LiveKit plan or wait for reset

## 🎯 Next Steps

Once connected successfully:

1. **Test voice functionality**:
   - Speak to Friday
   - Try weather queries: "What's the weather in New York?"
   - Test web search: "Search for latest tech news"

2. **Configure Gmail** (optional):
   - Set up Gmail App Password for email functionality
   - Test email sending

## 📞 Support

If you continue having issues:
1. Check LiveKit documentation: [https://docs.livekit.io/](https://docs.livekit.io/)
2. Verify your credentials in LiveKit dashboard
3. Contact LiveKit support if needed

---

**"At your service, Sir."** - Friday Jarvis 