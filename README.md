# Friday Jarvis - AI Personal Assistant

A voice-enabled AI personal assistant inspired by the AI from Iron Man, built with LiveKit Agents and Google's Realtime AI.

## 🎯 Overview

Friday Jarvis is a sophisticated voice assistant that combines real-time speech processing with powerful AI capabilities. The assistant speaks like a classy butler with a touch of sarcasm, providing a unique and engaging user experience.

## 🚀 Features

### Core Capabilities
- **Voice Interaction**: Real-time speech-to-text and text-to-speech using Google's Realtime AI
- **Weather Information**: Get current weather data for any city worldwide
- **Web Search**: Search the internet using DuckDuckGo for real-time information
- **Email Management**: Send emails through Gmail with support for CC recipients
- **Noise Cancellation**: Enhanced audio processing for crystal-clear communication

### Personality
- Speaks like a classy butler with sarcastic undertones
- Responds in concise, single-sentence answers
- Uses characteristic phrases like "Will do, Sir", "Roger Boss", "Check!"
- Acknowledges tasks before execution and reports completion

## 📁 Project Structure

```
friday_jarvis-main/
├── agent.py          # Main agent implementation and LiveKit integration
├── prompts.py        # AI personality and instruction prompts
├── tools.py          # Custom tools for weather, search, and email
├── requirements.txt  # Python dependencies
└── README.md        # This documentation
```

## 🛠️ Installation

### Prerequisites
- Python 3.8 or higher
- Gmail account with App Password (for email functionality)
- LiveKit account (for voice processing)

### Setup Instructions

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd friday_jarvis-main
   ```

2. **Install dependencies**
   ```bash
   pip install -r requirements.txt
   ```

3. **Configure environment variables**
   Create a `.env` file in the project root:
   ```env
   GMAIL_USER=your-email@gmail.com
   GMAIL_APP_PASSWORD=your-app-password
   ```

4. **Configure LiveKit credentials**
   Set up your LiveKit credentials according to the LiveKit documentation.

## 🔧 Configuration

### Environment Variables
- `GMAIL_USER`: Your Gmail email address
- `GMAIL_APP_PASSWORD`: Gmail App Password (not regular password)

### Gmail Setup
1. Enable 2-Factor Authentication on your Gmail account
2. Generate an App Password:
   - Go to Google Account settings
   - Security → 2-Step Verification → App passwords
   - Generate a password for "Mail"
3. Use this App Password in your `.env` file

## 🎙️ Usage

### Running the Assistant
```bash
python agent.py
```

### Voice Commands Examples
- "What's the weather like in New York?"
- "Search for the latest tech news"
- "Send an email to john@example.com with subject 'Meeting' and message 'Let's meet tomorrow'"

## 🧩 Core Components

### Agent (`agent.py`)
The main entry point that:
- Initializes the AI assistant with Google's Realtime model
- Configures voice settings (Aoede voice, temperature 0.8)
- Sets up noise cancellation for enhanced audio quality
- Manages the LiveKit session and room connections

### Tools (`tools.py`)
Three main tools that extend the assistant's capabilities:

#### 1. Weather Tool
- **Function**: `get_weather(city: str)`
- **Service**: Uses wttr.in API
- **Returns**: Current weather information for specified city

#### 2. Web Search Tool
- **Function**: `search_web(query: str)`
- **Service**: DuckDuckGo search engine
- **Returns**: Search results for any web query

#### 3. Email Tool
- **Function**: `send_email(to_email, subject, message, cc_email=None)`
- **Service**: Gmail SMTP
- **Features**: Supports CC recipients, error handling, secure authentication

### Prompts (`prompts.py`)
Defines the AI's personality and behavior:
- **AGENT_INSTRUCTION**: Core personality and response style
- **SESSION_INSTRUCTION**: Initial greeting and task guidelines

## 🔌 Dependencies

### Core Dependencies
- `livekit-agents`: Main LiveKit agents framework
- `livekit-plugins-google`: Google AI integration
- `livekit-plugins-noise-cancellation`: Audio enhancement
- `mem0ai`: Memory management for conversations
- `duckduckgo-search`: Web search functionality
- `langchain_community`: AI tool integration
- `requests`: HTTP requests for weather API
- `python-dotenv`: Environment variable management

## 🎨 Voice Configuration

### Current Settings
- **Voice Model**: Google's Realtime AI
- **Voice**: Aoede
- **Temperature**: 0.8 (balanced creativity and consistency)
- **Noise Cancellation**: BVC (Best Voice Clarity)

## 🔒 Security Features

- Environment variable-based credential management
- Gmail App Password authentication
- TLS encryption for email transmission
- Error handling and logging for all operations

## 🐛 Troubleshooting

### Common Issues

1. **Gmail Authentication Error**
   - Ensure you're using an App Password, not your regular password
   - Verify 2-Factor Authentication is enabled
   - Check that credentials are correctly set in `.env`

2. **Voice Connection Issues**
   - Verify LiveKit credentials are properly configured
   - Check network connectivity
   - Ensure microphone permissions are granted

3. **Weather API Errors**
   - Check internet connectivity
   - Verify city name spelling
   - API may have rate limits

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🙏 Acknowledgments

- Inspired by the AI assistant "Friday" from Iron Man
- Built with LiveKit for real-time communication
- Powered by Google's Realtime AI for voice processing
- Uses DuckDuckGo for privacy-focused web search

## 📞 Support

For issues and questions:
1. Check the troubleshooting section
2. Review LiveKit documentation
3. Open an issue on the repository

---

**"At your service, Sir."** - Friday Jarvis 