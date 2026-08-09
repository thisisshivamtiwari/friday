const statusPill = document.getElementById('statusPill');
const transcriptBox = document.getElementById('transcriptBox');
const contextInput = document.getElementById('contextInput');
const apiKeyInput = document.getElementById('apiKeyInput');
const startBtn = document.getElementById('startBtn');
const stopBtn = document.getElementById('stopBtn');
const clearBtn = document.getElementById('clearBtn');
const topicText = document.getElementById('topicText');
const interventionText = document.getElementById('interventionText');
const cueText = document.getElementById('cueText');

let recognition = null;
let listening = false;
let transcriptHistory = '';

function setStatus(text, tone = 'neutral') {
  statusPill.textContent = text;
  statusPill.style.background = tone === 'active'
    ? 'rgba(94, 231, 199, 0.16)'
    : tone === 'warning'
      ? 'rgba(255, 191, 0, 0.16)'
      : 'rgba(94, 231, 199, 0.12)';
}

function updateTranscript(text) {
  transcriptBox.textContent = text;
}

function buildSuggestion(transcript, context) {
  const combined = `${transcript}\n${context}`.toLowerCase();
  const topic = detectTopic(combined);
  const intervention = generateIntervention(topic, transcript);
  const cue = generateCue(topic, transcript);
  topicText.textContent = topic;
  interventionText.textContent = intervention;
  cueText.textContent = cue;
}

function detectTopic(text) {
  if (text.includes('agentic') || text.includes('agents')) {
    return 'Agentic AI and workflow automation';
  }
  if (text.includes('regulation') || text.includes('governance')) {
    return 'AI regulation and responsible adoption';
  }
  if (text.includes('uae') || text.includes('dubai') || text.includes('gulf')) {
    return 'Regional ecosystem and UAE market dynamics';
  }
  if (text.includes('startup') || text.includes('founder')) {
    return 'Startup strategy and founder decision-making';
  }
  if (text.includes('product') || text.includes('customer')) {
    return 'Product and customer focus';
  }
  if (text.includes('ops') || text.includes('operations') || text.includes('execution')) {
    return 'Operations and execution priorities';
  }
  return 'General strategic discussion';
}

function generateIntervention(topic, transcript) {
  const prefix = 'A strong line could be:';
  if (topic.includes('Agentic AI')) {
    return `${prefix} "From a founder's lens, the real question is whether this reduces friction for the team or creates a new dependency."`;
  }
  if (topic.includes('regulation')) {
    return `${prefix} "I think the balance is to move fast, but with clear guardrails around trust, risk, and accountability."`;
  }
  if (topic.includes('UAE')) {
    return `${prefix} "That makes sense especially in the UAE context, where speed, partnerships, and execution quality often matter as much as the idea itself."`;
  }
  if (topic.includes('Startup')) {
    return `${prefix} "I'd like to build on that point by framing it as a decision trade-off between speed, focus, and long-term leverage."`;
  }
  if (transcript.trim().length < 20) {
    return `${prefix} "I'd like to add a simple structure here: problem, analysis, and recommendation."`;
  }
  return `${prefix} "Another perspective is that the core issue is not just the idea, but the operating model that supports it."`;
}

function generateCue(topic, transcript) {
  if (transcript.trim().length < 20) {
    return 'Wait for a clear turn in the discussion, then add a short framing sentence.';
  }
  if (topic.includes('Agentic AI')) {
    return 'Use a short intervention when the room moves from hype to implementation trade-offs.';
  }
  if (topic.includes('UAE')) {
    return 'Bring in the regional angle once the discussion shifts from abstract ideas to market reality.';
  }
  return 'Enter with one sentence that connects the current point to a practical decision or trade-off.';
}

async function askOpenAI(transcript, context) {
  const apiKey = apiKeyInput.value.trim();
  if (!apiKey) {
    return null;
  }

  try {
    const response = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: 'gpt-4o-mini',
        messages: [
          {
            role: 'system',
            content: 'You help a founder-office candidate in a live group discussion. Return three short items: topic, intervention, cue. Keep it concise and founder-minded.'
          },
          {
            role: 'user',
            content: `Context:\n${context}\n\nTranscript:\n${transcript}`
          }
        ],
        temperature: 0.7,
      })
    });

    if (!response.ok) {
      throw new Error('OpenAI request failed');
    }

    const data = await response.json();
    const text = data.choices?.[0]?.message?.content ?? '';
    return text;
  } catch (error) {
    console.warn('OpenAI fallback used:', error);
    return null;
  }
}

function initRecognition() {
  const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SpeechRecognition) {
    setStatus('Speech API unavailable', 'warning');
    topicText.textContent = 'Your browser does not support live transcription.';
    interventionText.textContent = 'Use Chrome or Edge for the best experience.';
    cueText.textContent = 'Switch browsers or use the offline rule-based mode.';
    return;
  }

  recognition = new SpeechRecognition();
  recognition.lang = 'en-US';
  recognition.continuous = true;
  recognition.interimResults = true;

  recognition.onstart = () => {
    listening = true;
    setStatus('Listening', 'active');
  };

  recognition.onerror = (event) => {
    console.error(event.error);
    setStatus('Listening error', 'warning');
  };

  recognition.onend = () => {
    listening = false;
    setStatus('Stopped', 'neutral');
  };

  recognition.onresult = async (event) => {
    let transcript = '';
    for (let i = event.resultIndex; i < event.results.length; i += 1) {
      transcript += event.results[i][0].transcript;
    }

    transcriptHistory = transcript.trim();
    updateTranscript(transcriptHistory);
    buildSuggestion(transcriptHistory, contextInput.value);

    const aiResponse = await askOpenAI(transcriptHistory, contextInput.value);
    if (aiResponse) {
      const lines = aiResponse.split('\n').filter(Boolean);
      const topicLine = lines[0] || 'Topic';
      const interventionLine = lines[1] || 'Intervention';
      const cueLine = lines[2] || 'Cue';
      topicText.textContent = topicLine.replace(/^topic\s*[:\-]\s*/i, '');
      interventionText.textContent = interventionLine.replace(/^intervention\s*[:\-]\s*/i, '');
      cueText.textContent = cueLine.replace(/^cue\s*[:\-]\s*/i, '');
    }
  };
}

startBtn.addEventListener('click', () => {
  if (!recognition) {
    initRecognition();
  }
  if (recognition && !listening) {
    recognition.start();
  }
});

stopBtn.addEventListener('click', () => {
  if (recognition && listening) {
    recognition.stop();
  }
});

clearBtn.addEventListener('click', () => {
  transcriptHistory = '';
  updateTranscript('');
  buildSuggestion('', contextInput.value);
});

contextInput.addEventListener('input', () => {
  buildSuggestion(transcriptHistory, contextInput.value);
});

initRecognition();
buildSuggestion('', contextInput.value);
