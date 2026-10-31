# Kaddo: inputs, processing, and outputs

This flowchart describes the current macOS app behavior and the main input/output
contracts. “Selected AI provider” means the provider chosen in AI settings: OpenAI,
DeepSeek, or local Ollama. Kaddo does not automatically switch providers on failure.

```mermaid
flowchart TD
    U[User] --> C{Input to Kaddo}

    C -->|Typed message\nup to 2,000 characters| CHAT[Companion composer]
    CHAT --> ROUTE{Recognized complete offline action?}
    ROUTE -->|Yes: supported timer, task, note, reminder, etc.| CMD[NaturalActionRouter\nnormalize to planner command]
    CMD --> PLAN[StudentPlanner\nvalidate and save or read]
    PLAN --> POUT[Confirmation, current list/status,\nor a question for missing details]

    ROUTE -->|No: conversation, question,\nambiguous request or guided answer| COORD[AssistantCoordinator\nadds bounded chat context and routes request]
    COORD --> PROVIDER[Selected AI provider\nOpenAI / DeepSeek / Ollama]
    PROVIDER -->|Plain answer| REPLY[Streamed answer and pet state\ntext, emotion, citations when applicable]
    PROVIDER -->|Structured tool request| TOOL[KaddoToolExecutor\nregistered tools, typed arguments, stable IDs]
    TOOL -->|Read or change planner data| PLAN
    TOOL -->|Search saved knowledge| KB[Local KnowledgeLibrary\nSQLite knowledge and agent state]
    TOOL -->|Ask about uploaded files| DOCQ[DocumentRetrievalService]
    DOCQ --> DOCS[Saved text + ranked chunks\ncurrent permitted document scope]
    DOCS -->|Question + bounded matching evidence| DOCANS[Grounded document answering\nno action tools]
    DOCANS --> REPLY
    POUT --> REPLY
    REPLY --> OUT[Visible chat reply, citations,\nclarification, or action result]

    U -->|PDF / DOCX / TXT / Markdown\nfile picker or drop on pet| UPLOAD[DocumentIngestionService]
    UPLOAD --> TEXT[Extract readable text\nOCR/visual interpretation where supported]
    TEXT --> SAVE[Save document/session record locally]
    SAVE --> ANALYZE[Selected AI provider analyzes bounded text\nfor filing + supported planner entries]
    ANALYZE --> VALIDATE[Validate category, exact evidence,\nentry fields and dates]
    VALIDATE -->|Supported task / assignment / exam / class| PLAN
    VALIDATE -->|Unclear or conflicting detail| ASK[Ask user in chat\nfile remains saved; skip or clarify]
    VALIDATE -->|Success| UPREPLY[Upload result: filename, chosen category,\nsaved entries, indexing status and evidence]
    SAVE --> INDEX[Local chunking + SQLite search index\noptional local Ollama embeddings]
    INDEX --> DOCS

    U -->|Personal-agent request, approved source,\nsaved prompt or due routine| AGENT[AgentPlatform]
    AGENT -->|Folder: TXT/Markdown/PDF/DOCX, up to 8 MB\nHTTPS page: public URL only| SRC[Bounded, read-only source reader]
    SRC -->|Selected source excerpts + request| PROVIDER
    AGENT -->|Substantive conversation may suggest memory| SUGGEST[Suggestion with supporting quote]
    SUGGEST -->|User accepts / corrects| KB
    AGENT -->|Scheduled routine while app is open\nread-only, no tools| BRIEF[Briefing in activity tray]

    PLAN --> STORE1[(Local planner JSON)]
    KB --> STORE2[(Local knowledge SQLite)]
    OUT --> PET[Pet UI: speech, emotion, activity tray,\nnotifications for configured alerts]
```

## Input and output quick reference

| Input | What Kaddo does | Output |
| --- | --- | --- |
| Chat text (up to 2,000 characters) | Runs a narrow offline action matcher first; otherwise uses the selected provider with recent conversation context. Tool requests are validated and run sequentially, up to eight per message. | Natural answer, saved/read planner result, clarification, or explicit error. |
| Planner request | Accepts recognized commands for tasks, dates, classes, timers, reminders, notes, flashcards, schedule/profile reads, and related controls. Missing required fields prompt a follow-up. | Confirmation or requested data; persistent planner changes save locally. |
| PDF, DOCX, TXT, or Markdown file | Extracts text, saves it, categorizes it, and detects supported task/deadline/class entries. Indexing and embeddings are local. | Upload summary with destination, planner entries, evidence and index readiness; asks for clarification if needed. |
| Document question | Retrieves ranked excerpts from the relevant documents; explicit filenames narrow the search. Answers receive only bounded evidence and cannot run actions. | Evidence-grounded answer with document citations, or a clear no-match/insufficient-context reply. |
| Personal-agent source request | Reads a public HTTPS page or user-approved folder files using bounded, read-only access. No web search or authenticated browser pages. | Source-grounded answer with source citations; source text is temporary. |
| Scheduled personal-agent routine | Runs a saved prompt against selected sources while Kaddo is open; inference has no tools. | Read-only briefing in the activity tray, or a retryable failure. |
| Memory suggestion | May propose one stable user detail with an exact supporting quote; it does not directly turn source/document content into memory. | User reviews and saves, corrects, or dismisses it. |

## Local and remote boundaries

- Planner records are stored in local JSON. Uploaded text, document indexes, saved
  knowledge, and agent state are in the local SQLite knowledge database.
- Ollama chat and embedding requests run locally. OpenAI and DeepSeek requests go to
  the configured cloud provider. Cloud document answers receive only retrieved excerpts;
  embeddings remain local.
- Personal-agent source reads are separate from general chat. Scheduled routines are
  read-only and cannot create planner entries, save memories, or change settings.
