//! Headless entry point for the Tuist Code Rust coding agent.
//!
//! The runner intentionally has no graphical dependency. It emits JSON Lines
//! on standard output, accepts approval decisions on standard input when
//! `--interactive` is set, and talks directly to a selected inference provider.

use std::{
    collections::BTreeMap,
    env,
    io::{self, BufRead, BufReader, Write},
    path::PathBuf,
    process::{Command, Stdio},
};

use tuist_code_shared::{
    AgentTool,
    agent::{
        AgentEvent, AgentInteraction, AgentLoopError, AgentMessage, AgentModel, AgentModelRequest,
        AgentModelResponse, AgentRunConfiguration, AgentToolCall, AgentToolInput, run_agent,
    },
};

const API_KEY_ENVIRONMENT_VARIABLE: &str = "TUIST_CODE_AGENT_API_KEY";
const DEFAULT_SYSTEM_PROMPT: &str = "You are Tuist Code's coding agent. Work only inside the supplied Git worktree. Inspect before changing files, use the available tools deliberately, and ask the human when requirements are unclear. Read-only tools run immediately. Mutating tools require explicit approval.";

#[derive(Clone, Copy)]
enum Provider {
    Together,
    Fireworks,
    Codex,
}

impl Provider {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "together" => Ok(Self::Together),
            "fireworks" => Ok(Self::Fireworks),
            "codex" => Ok(Self::Codex),
            _ => Err(format!(
                "Unsupported provider '{value}'. Use 'together', 'fireworks', or 'codex'."
            )),
        }
    }

    const fn endpoint(self) -> Option<&'static str> {
        match self {
            Self::Together => Some("https://api.together.ai/v1/chat/completions"),
            Self::Fireworks => Some("https://api.fireworks.ai/inference/v1/chat/completions"),
            Self::Codex => None,
        }
    }
}

#[derive(Clone, Copy)]
enum ApprovalPolicy {
    Deny,
    Allow,
    Interactive,
}

struct CommandLine {
    provider: Provider,
    model: String,
    worktree: PathBuf,
    prompt: String,
    system_prompt: String,
    reasoning: Option<String>,
    maximum_turns: usize,
    approval_policy: ApprovalPolicy,
}

fn main() {
    let command_line = match parse_command_line() {
        Ok(command_line) => command_line,
        Err(error) => {
            eprintln!("{error}\n\n{}", usage());
            std::process::exit(2);
        }
    };

    if !command_line.worktree.is_dir() {
        eprintln!(
            "The worktree path does not exist or is not a directory: {}",
            command_line.worktree.display()
        );
        std::process::exit(2);
    }

    if matches!(command_line.provider, Provider::Codex) {
        if let Err(error) = run_codex_subscription_agent(&command_line) {
            emit_message_error(&error);
            std::process::exit(1);
        }
        return;
    }

    let api_key = match env::var(API_KEY_ENVIRONMENT_VARIABLE) {
        Ok(api_key) if !api_key.is_empty() => api_key,
        _ => {
            eprintln!(
                "Set {API_KEY_ENVIRONMENT_VARIABLE} to the selected provider's application programming interface key."
            );
            std::process::exit(2);
        }
    };

    let mut model = OpenAICompatibleModel {
        endpoint: command_line
            .provider
            .endpoint()
            .expect("network provider has an endpoint"),
        api_key,
        model: command_line.model,
    };
    let mut interaction = StandardInputInteraction::new(command_line.approval_policy);
    let mut configuration = AgentRunConfiguration::new(
        command_line.worktree,
        command_line.system_prompt,
        command_line.prompt,
    );
    configuration.maximum_turns = command_line.maximum_turns;

    match run_agent(configuration, &mut model, &mut interaction, emit_event) {
        Ok(_) => {}
        Err(error) => {
            emit_error(&error);
            std::process::exit(1);
        }
    }
}

fn parse_command_line() -> Result<CommandLine, String> {
    let mut provider = None;
    let mut model = None;
    let mut worktree = None;
    let mut prompt = None;
    let mut system_prompt = DEFAULT_SYSTEM_PROMPT.to_owned();
    let mut reasoning = None;
    let mut maximum_turns = 30;
    let mut approval_policy = ApprovalPolicy::Deny;
    let mut arguments = env::args().skip(1);

    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--help" | "-h" => {
                println!("{}", usage());
                std::process::exit(0);
            }
            "--provider" => {
                let value = next_argument(&mut arguments, "--provider")?;
                provider = Some(Provider::parse(&value)?);
            }
            "--model" => model = Some(next_argument(&mut arguments, "--model")?),
            "--worktree" => {
                worktree = Some(PathBuf::from(next_argument(&mut arguments, "--worktree")?))
            }
            "--prompt" => prompt = Some(next_argument(&mut arguments, "--prompt")?),
            "--system-prompt" => system_prompt = next_argument(&mut arguments, "--system-prompt")?,
            "--reasoning" => reasoning = Some(next_argument(&mut arguments, "--reasoning")?),
            "--maximum-turns" => {
                let value = next_argument(&mut arguments, "--maximum-turns")?;
                maximum_turns = value
                    .parse::<usize>()
                    .map_err(|_| "--maximum-turns must be a positive integer.".to_owned())?;
                if maximum_turns == 0 {
                    return Err("--maximum-turns must be a positive integer.".to_owned());
                }
            }
            "--approve" => approval_policy = ApprovalPolicy::Allow,
            "--interactive" => approval_policy = ApprovalPolicy::Interactive,
            _ => return Err(format!("Unknown argument '{argument}'.")),
        }
    }

    Ok(CommandLine {
        provider: provider.ok_or_else(|| "Missing required --provider argument.".to_owned())?,
        model: model.ok_or_else(|| "Missing required --model argument.".to_owned())?,
        worktree: worktree.ok_or_else(|| "Missing required --worktree argument.".to_owned())?,
        prompt: prompt.ok_or_else(|| "Missing required --prompt argument.".to_owned())?,
        system_prompt,
        reasoning,
        maximum_turns,
        approval_policy,
    })
}

fn next_argument(
    arguments: &mut impl Iterator<Item = String>,
    option: &str,
) -> Result<String, String> {
    arguments
        .next()
        .ok_or_else(|| format!("Missing value for {option}."))
}

fn usage() -> &'static str {
    "Usage:\n  tuist-code-agent --provider <together|fireworks|codex> --model <model> --worktree <path> --prompt <task> [--reasoning <level>] [--interactive|--approve]\n\nThe runner emits JSON Lines events on standard output. Mutating tools are denied by default. Use --interactive to reply with 'allow' or 'deny' on standard input for each requested mutation, or --approve only when you explicitly want to permit all mutations.\n\nSet TUIST_CODE_AGENT_API_KEY with the application programming interface key for Together AI or Fireworks AI. Codex uses the locally signed-in Codex application server."
}

/// Runs a Codex-backed session through its documented local application server.
///
/// This is deliberately separate from `codex exec`: the user keeps their
/// existing Codex subscription sign-in, while Tuist Code controls the process
/// lifecycle and relays every approval through its own session user interface.
fn run_codex_subscription_agent(command_line: &CommandLine) -> Result<(), String> {
    let executable = env::var("TUIST_CODE_CODEX_EXECUTABLE").unwrap_or_else(|_| "codex".to_owned());
    let mut child = Command::new(executable)
        .args(["app-server", "--stdio"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("Unable to start the local Codex application server: {error}"))?;
    let mut input = child
        .stdin
        .take()
        .ok_or_else(|| "Unable to write to the Codex application server.".to_owned())?;
    let output = child
        .stdout
        .take()
        .ok_or_else(|| "Unable to read from the Codex application server.".to_owned())?;
    let mut output = BufReader::new(output);

    write_json_rpc_request(
        &mut input,
        "1",
        "initialize",
        r#"{"clientInfo":{"name":"Tuist Code","version":"1.0"},"capabilities":{}}"#,
    )?;

    let mut thread_id = None;
    let mut turn_started = false;
    let mut line = String::new();
    loop {
        line.clear();
        let bytes = output
            .read_line(&mut line)
            .map_err(|error| format!("Unable to read Codex events: {error}"))?;
        if bytes == 0 {
            return Err(
                "The local Codex application server stopped before completing the turn.".to_owned(),
            );
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let event = match JsonParser::parse(trimmed) {
            Ok(event) => event,
            Err(_) => continue,
        };

        if event.matches_id("1") {
            let start_params = codex_thread_start_params(command_line);
            write_json_rpc_request(&mut input, "2", "thread/start", &start_params)?;
            continue;
        }

        if event.matches_id("2") {
            let id = event
                .field("result")
                .and_then(|result| result.field("thread"))
                .and_then(|thread| thread.optional_string_value("id"))
                .ok_or_else(|| "Codex did not return a thread identifier.".to_owned())?;
            thread_id = Some(id.to_owned());
            let turn_params = codex_turn_start_params(command_line, id);
            write_json_rpc_request(&mut input, "3", "turn/start", &turn_params)?;
            turn_started = true;
            emit_status("model_request", &format!("{{\"turn\":1}}"));
            continue;
        }

        if let Some(error) = event.field("error") {
            return Err(format!(
                "The Codex application server returned an error: {}",
                error.compact_json()
            ));
        }

        let Some(method) = event.optional_string_value("method") else {
            continue;
        };
        match method {
            "item/completed" => {
                if let Some(item) = event
                    .field("params")
                    .and_then(|params| params.field("item"))
                {
                    let item_type = item.optional_string_value("type").unwrap_or("activity");
                    if item_type == "agentMessage" {
                        if let Some(text) = item.optional_string_value("text") {
                            emit_status(
                                "assistant_message",
                                &format!("{{\"content\":{}}}", json_string(text)),
                            );
                        }
                    } else if matches!(item_type, "commandExecution" | "fileChange") {
                        emit_status(
                            "tool_completed",
                            &format!(
                                "{{\"tool\":{},\"output\":{}}}",
                                json_string(item_type),
                                json_string(&item.compact_json())
                            ),
                        );
                    }
                }
            }
            "item/commandExecution/requestApproval"
            | "item/fileChange/requestApproval"
            | "applyPatchApproval" => {
                let summary = event
                    .field("params")
                    .map(JsonValue::compact_json)
                    .unwrap_or_else(|| "Codex requested approval.".to_owned());
                emit_status(
                    "approval_requested",
                    &format!(
                        "{{\"tool\":{},\"summary\":{}}}",
                        json_string(method),
                        json_string(&summary)
                    ),
                );
                let approved = read_codex_approval(command_line.approval_policy);
                let result = if method == "applyPatchApproval" {
                    if approved {
                        r#"{"decision":"approved"}"#
                    } else {
                        r#"{"decision":"abort"}"#
                    }
                } else if approved {
                    r#"{"decision":"accept"}"#
                } else {
                    r#"{"decision":"decline"}"#
                };
                let id = event.field("id").ok_or_else(|| {
                    "Codex sent an approval request without an identifier.".to_owned()
                })?;
                write_json_rpc_response(&mut input, id, result)?;
            }
            "item/permissions/requestApproval" => {
                let summary = event
                    .field("params")
                    .map(JsonValue::compact_json)
                    .unwrap_or_else(|| "Codex requested additional permissions.".to_owned());
                emit_status(
                    "approval_requested",
                    &format!(
                        "{{\"tool\":\"additional permissions\",\"summary\":{}}}",
                        json_string(&summary)
                    ),
                );
                let id = event.field("id").ok_or_else(|| {
                    "Codex sent a permission request without an identifier.".to_owned()
                })?;
                // The Tuist Code session is intentionally bounded to its worktree.
                // A separate UI will be needed before granting expanded access.
                write_json_rpc_response(&mut input, id, r#"{"permissions":{}}"#)?;
            }
            "turn/completed" if turn_started && thread_id.is_some() => {
                emit_status("completed", "{}");
                let _ = child.kill();
                let _ = child.wait();
                return Ok(());
            }
            _ => {}
        }
    }
}

fn codex_thread_start_params(command_line: &CommandLine) -> String {
    format!(
        "{{\"cwd\":{},\"ephemeral\":true,\"approvalPolicy\":\"untrusted\",\"sandbox\":\"workspace-write\",\"model\":{},\"developerInstructions\":{}}}",
        json_string(command_line.worktree.to_string_lossy().as_ref()),
        json_string(&command_line.model),
        json_string(&command_line.system_prompt),
    )
}

fn codex_turn_start_params(command_line: &CommandLine, thread_id: &str) -> String {
    let effort = command_line
        .reasoning
        .as_deref()
        .filter(|value| *value != "none")
        .map(|value| format!(",\"effort\":{}", json_string(value)))
        .unwrap_or_default();
    format!(
        "{{\"threadId\":{},\"input\":[{{\"type\":\"text\",\"text\":{}}}],\"model\":{}{} }}",
        json_string(thread_id),
        json_string(&command_line.prompt),
        json_string(&command_line.model),
        effort,
    )
}

fn write_json_rpc_request(
    output: &mut impl Write,
    id: &str,
    method: &str,
    parameters: &str,
) -> Result<(), String> {
    writeln!(
        output,
        "{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":{},\"params\":{parameters}}}",
        json_string(method)
    )
    .and_then(|_| output.flush())
    .map_err(|error| format!("Unable to send a Codex request: {error}"))
}

fn write_json_rpc_response(
    output: &mut impl Write,
    id: &JsonValue,
    result: &str,
) -> Result<(), String> {
    writeln!(
        output,
        "{{\"jsonrpc\":\"2.0\",\"id\":{},\"result\":{result}}}",
        id.compact_json()
    )
    .and_then(|_| output.flush())
    .map_err(|error| format!("Unable to send a Codex approval: {error}"))
}

fn read_codex_approval(approval_policy: ApprovalPolicy) -> bool {
    match approval_policy {
        ApprovalPolicy::Allow => true,
        ApprovalPolicy::Deny => false,
        ApprovalPolicy::Interactive => {
            let mut reply = String::new();
            io::stdin().read_line(&mut reply).is_ok()
                && matches!(reply.trim(), "allow" | "approve" | "yes")
        }
    }
}

fn emit_status(event_type: &str, fields: &str) {
    let fields = fields
        .strip_prefix('{')
        .and_then(|value| value.strip_suffix('}'))
        .unwrap_or(fields);
    if fields.is_empty() {
        println!("{{\"type\":{}}}", json_string(event_type));
    } else {
        println!("{{\"type\":{},{} }}", json_string(event_type), fields);
    }
    let _ = io::stdout().flush();
}

fn emit_message_error(message: &str) {
    println!(
        "{{\"type\":\"error\",\"message\":{}}}",
        json_string(message)
    );
    let _ = io::stdout().flush();
}

struct OpenAICompatibleModel {
    endpoint: &'static str,
    api_key: String,
    model: String,
}

impl AgentModel for OpenAICompatibleModel {
    type Error = String;

    fn complete(&mut self, request: &AgentModelRequest) -> Result<AgentModelResponse, Self::Error> {
        let payload = format!(
            "{{\"model\":{},\"messages\":{},\"tools\":{},\"tool_choice\":\"auto\",\"stream\":false}}",
            json_string(&self.model),
            messages_json(&request.messages),
            tools_json(&request.tools),
        );
        let mut child = Command::new("curl")
            .args([
                "--fail-with-body",
                "--silent",
                "--show-error",
                "--request",
                "POST",
                self.endpoint,
                "--header",
                "Content-Type: application/json",
                "--header",
                &format!("Authorization: Bearer {}", self.api_key),
                "--data-binary",
                "@-",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| format!("Unable to launch curl: {error}"))?;

        let mut standard_input = child
            .stdin
            .take()
            .ok_or_else(|| "Unable to write the provider request.".to_owned())?;
        standard_input
            .write_all(payload.as_bytes())
            .map_err(|error| format!("Unable to send the provider request: {error}"))?;
        drop(standard_input);

        let output = child
            .wait_with_output()
            .map_err(|error| format!("Unable to receive the provider response: {error}"))?;
        let standard_output = String::from_utf8_lossy(&output.stdout).into_owned();
        if !output.status.success() {
            let standard_error = String::from_utf8_lossy(&output.stderr).trim().to_owned();
            return Err(if standard_error.is_empty() {
                format!("The provider request failed: {standard_output}")
            } else {
                format!("The provider request failed: {standard_error}")
            });
        }
        decode_provider_response(&standard_output)
    }
}

struct StandardInputInteraction {
    approval_policy: ApprovalPolicy,
}

impl StandardInputInteraction {
    const fn new(approval_policy: ApprovalPolicy) -> Self {
        Self { approval_policy }
    }

    fn read_reply(&self) -> Option<String> {
        let mut reply = String::new();
        io::stdin().read_line(&mut reply).ok()?;
        let reply = reply.trim().to_owned();
        (!reply.is_empty()).then_some(reply)
    }
}

impl AgentInteraction for StandardInputInteraction {
    fn approve(&mut self, _call: &AgentToolCall) -> bool {
        match self.approval_policy {
            ApprovalPolicy::Allow => true,
            ApprovalPolicy::Deny => false,
            ApprovalPolicy::Interactive => matches!(
                self.read_reply().as_deref(),
                Some("allow" | "approve" | "yes")
            ),
        }
    }

    fn answer(&mut self, _question: &str) -> Option<String> {
        match self.approval_policy {
            ApprovalPolicy::Interactive => self.read_reply(),
            ApprovalPolicy::Allow | ApprovalPolicy::Deny => None,
        }
    }
}

fn emit_event(event: AgentEvent) {
    let value = match event {
        AgentEvent::ModelRequest { turn } => {
            format!("{{\"type\":\"model_request\",\"turn\":{turn}}}")
        }
        AgentEvent::AssistantMessage(content) => format!(
            "{{\"type\":\"assistant_message\",\"content\":{}}}",
            json_string(&content)
        ),
        AgentEvent::ApprovalRequested { tool, summary } => format!(
            "{{\"type\":\"approval_requested\",\"tool\":{},\"summary\":{}}}",
            json_string(tool_name(tool)),
            json_string(&summary)
        ),
        AgentEvent::ToolCompleted { tool, output } => format!(
            "{{\"type\":\"tool_completed\",\"tool\":{},\"output\":{}}}",
            json_string(tool_name(tool)),
            json_string(&output)
        ),
        AgentEvent::ToolFailed { tool, error } => format!(
            "{{\"type\":\"tool_failed\",\"tool\":{},\"error\":{}}}",
            json_string(tool_name(tool)),
            json_string(&format!("{error:?}"))
        ),
        AgentEvent::UserQuestion(question) => format!(
            "{{\"type\":\"user_question\",\"question\":{}}}",
            json_string(&question)
        ),
        AgentEvent::Completed => "{\"type\":\"completed\"}".to_owned(),
    };
    println!("{value}");
    let _ = io::stdout().flush();
}

fn emit_error(error: &AgentLoopError) {
    let message = match error {
        AgentLoopError::Model(message) => message,
        AgentLoopError::MaximumTurnsReached => "The agent reached its maximum number of turns.",
    };
    println!(
        "{{\"type\":\"error\",\"message\":{}}}",
        json_string(message)
    );
    let _ = io::stdout().flush();
}

fn messages_json(messages: &[AgentMessage]) -> String {
    let values = messages
        .iter()
        .map(|message| match message {
            AgentMessage::System(content) => format!(
                "{{\"role\":\"system\",\"content\":{}}}",
                json_string(content)
            ),
            AgentMessage::User(content) => {
                format!("{{\"role\":\"user\",\"content\":{}}}", json_string(content))
            }
            AgentMessage::Assistant {
                content,
                tool_calls,
            } => format!(
                "{{\"role\":\"assistant\",\"content\":{},\"tool_calls\":{}}}",
                optional_json_string(content.as_deref()),
                tool_calls_json(tool_calls)
            ),
            AgentMessage::Tool { call_id, content } => format!(
                "{{\"role\":\"tool\",\"tool_call_id\":{},\"content\":{}}}",
                json_string(call_id),
                json_string(content)
            ),
        })
        .collect::<Vec<_>>();
    format!("[{}]", values.join(","))
}

fn tool_calls_json(tool_calls: &[AgentToolCall]) -> String {
    let values = tool_calls
        .iter()
        .map(|call| {
            format!(
                "{{\"id\":{},\"type\":\"function\",\"function\":{{\"name\":{},\"arguments\":{}}}}}",
                json_string(&call.id),
                json_string(tool_name(call.input.tool())),
                json_string(&tool_input_json(&call.input))
            )
        })
        .collect::<Vec<_>>();
    format!("[{}]", values.join(","))
}

fn tool_input_json(input: &AgentToolInput) -> String {
    match input {
        AgentToolInput::Read {
            path,
            offset,
            limit,
        } => format!(
            "{{\"path\":{},\"offset\":{offset},\"limit\":{limit}}}",
            json_string(path)
        ),
        AgentToolInput::List { path } | AgentToolInput::Ls { path } => {
            format!("{{\"path\":{}}}", json_string(path))
        }
        AgentToolInput::Glob { pattern }
        | AgentToolInput::Find { pattern }
        | AgentToolInput::Grep { pattern } => {
            format!("{{\"pattern\":{}}}", json_string(pattern))
        }
        AgentToolInput::Write { path, content } => format!(
            "{{\"path\":{},\"content\":{}}}",
            json_string(path),
            json_string(content)
        ),
        AgentToolInput::Edit {
            path,
            old_text,
            new_text,
        } => format!(
            "{{\"path\":{},\"old_text\":{},\"new_text\":{}}}",
            json_string(path),
            json_string(old_text),
            json_string(new_text)
        ),
        AgentToolInput::ApplyPatch { patch } => {
            format!("{{\"patch\":{}}}", json_string(patch))
        }
        AgentToolInput::Shell { command } | AgentToolInput::Bash { command } => {
            format!("{{\"command\":{}}}", json_string(command))
        }
        AgentToolInput::GitStatus | AgentToolInput::GitDiff => "{}".to_owned(),
        AgentToolInput::AskUser { question } => {
            format!("{{\"question\":{}}}", json_string(question))
        }
    }
}

fn tools_json(tools: &[AgentTool]) -> String {
    let tools = tools
        .iter()
        .map(|tool| {
            let (description, properties, required) = tool_schema(*tool);
            let properties = properties
                .iter()
                .map(|(name, kind)| {
                    format!(
                        "{}:{{\"type\":{}}}",
                        json_string(name),
                        json_string(kind)
                    )
                })
                .collect::<Vec<_>>()
                .join(",");
            let required = required
                .iter()
                .map(|name| json_string(name))
                .collect::<Vec<_>>()
                .join(",");
            let parameters = format!(
                "{{\"type\":\"object\",\"properties\":{{{properties}}},\"required\":[{required}],\"additionalProperties\":false}}"
            );
            let mut definition = String::from("{\"type\":\"function\",\"function\":{\"name\":");
            definition.push_str(&json_string(tool_name(*tool)));
            definition.push_str(",\"description\":");
            definition.push_str(&json_string(description));
            definition.push_str(",\"parameters\":");
            definition.push_str(&parameters);
            definition.push_str("}}");
            definition
        })
        .collect::<Vec<_>>();
    format!("[{}]", tools.join(","))
}

fn tool_schema(
    tool: AgentTool,
) -> (
    &'static str,
    &'static [(&'static str, &'static str)],
    &'static [&'static str],
) {
    match tool {
        AgentTool::Read => (
            "Read a text file in the worktree.",
            &[
                ("path", "string"),
                ("offset", "integer"),
                ("limit", "integer"),
            ],
            &["path"],
        ),
        AgentTool::List | AgentTool::Ls => (
            "List a directory in the worktree.",
            &[("path", "string")],
            &["path"],
        ),
        AgentTool::Glob | AgentTool::Find => (
            "Find files using a wildcard pattern.",
            &[("pattern", "string")],
            &["pattern"],
        ),
        AgentTool::Grep => (
            "Search text files in the worktree.",
            &[("pattern", "string")],
            &["pattern"],
        ),
        AgentTool::Write => (
            "Create or replace a text file. Requires approval.",
            &[("path", "string"), ("content", "string")],
            &["path", "content"],
        ),
        AgentTool::Edit => (
            "Replace one exact text range in a file. Requires approval.",
            &[
                ("path", "string"),
                ("old_text", "string"),
                ("new_text", "string"),
            ],
            &["path", "old_text", "new_text"],
        ),
        AgentTool::ApplyPatch => (
            "Apply a unified Git patch. Requires approval.",
            &[("patch", "string")],
            &["patch"],
        ),
        AgentTool::Shell | AgentTool::Bash => (
            "Run a shell command in the worktree. Requires approval.",
            &[("command", "string")],
            &["command"],
        ),
        AgentTool::GitStatus => ("Show the Git working tree status.", &[], &[]),
        AgentTool::GitDiff => ("Show unstaged Git changes.", &[], &[]),
        AgentTool::AskUser => (
            "Ask the human for information needed to continue.",
            &[("question", "string")],
            &["question"],
        ),
    }
}

fn tool_name(tool: AgentTool) -> &'static str {
    match tool {
        AgentTool::Read => "read",
        AgentTool::List => "list",
        AgentTool::Ls => "ls",
        AgentTool::Glob => "glob",
        AgentTool::Find => "find",
        AgentTool::Grep => "grep",
        AgentTool::Write => "write",
        AgentTool::Edit => "edit",
        AgentTool::ApplyPatch => "apply_patch",
        AgentTool::Shell => "shell",
        AgentTool::Bash => "bash",
        AgentTool::GitStatus => "git_status",
        AgentTool::GitDiff => "git_diff",
        AgentTool::AskUser => "ask_user",
    }
}

fn decode_provider_response(value: &str) -> Result<AgentModelResponse, String> {
    let response = JsonParser::parse(value)?;
    let choices = response
        .object_field("choices")?
        .array_value()
        .ok_or_else(|| "The provider response did not contain choices.".to_owned())?;
    let choice = choices
        .first()
        .ok_or_else(|| "The provider response did not contain a choice.".to_owned())?;
    let message = choice.object_field("message")?;
    let content = message.optional_string("content")?;
    let tool_calls = match message.optional_array("tool_calls")? {
        Some(tool_calls) => tool_calls
            .iter()
            .enumerate()
            .map(|(index, call)| decode_tool_call(call, index))
            .collect::<Result<Vec<_>, _>>()?,
        None => vec![],
    };
    Ok(AgentModelResponse {
        content,
        tool_calls,
    })
}

fn decode_tool_call(value: &JsonValue, index: usize) -> Result<AgentToolCall, String> {
    let id = value
        .optional_string("id")?
        .unwrap_or_else(|| format!("tool-call-{index}"));
    let function = value.object_field("function")?;
    let name = function.string_field("name")?;
    let arguments = function
        .optional_string("arguments")?
        .unwrap_or_else(|| "{}".to_owned());
    Ok(AgentToolCall {
        id,
        input: decode_tool_input(&name, &arguments)?,
    })
}

fn decode_tool_input(name: &str, arguments: &str) -> Result<AgentToolInput, String> {
    let arguments = JsonParser::parse(arguments)?;
    match name {
        "read" => Ok(AgentToolInput::Read {
            path: arguments.string_field("path")?,
            offset: arguments.optional_usize("offset")?.unwrap_or(0),
            limit: arguments.optional_usize("limit")?.unwrap_or(200),
        }),
        "list" => Ok(AgentToolInput::List {
            path: arguments.string_field("path")?,
        }),
        "ls" => Ok(AgentToolInput::Ls {
            path: arguments.string_field("path")?,
        }),
        "glob" => Ok(AgentToolInput::Glob {
            pattern: arguments.string_field("pattern")?,
        }),
        "find" => Ok(AgentToolInput::Find {
            pattern: arguments.string_field("pattern")?,
        }),
        "grep" => Ok(AgentToolInput::Grep {
            pattern: arguments.string_field("pattern")?,
        }),
        "write" => Ok(AgentToolInput::Write {
            path: arguments.string_field("path")?,
            content: arguments.string_field("content")?,
        }),
        "edit" => Ok(AgentToolInput::Edit {
            path: arguments.string_field("path")?,
            old_text: arguments.string_field("old_text")?,
            new_text: arguments.string_field("new_text")?,
        }),
        "apply_patch" => Ok(AgentToolInput::ApplyPatch {
            patch: arguments.string_field("patch")?,
        }),
        "shell" => Ok(AgentToolInput::Shell {
            command: arguments.string_field("command")?,
        }),
        "bash" => Ok(AgentToolInput::Bash {
            command: arguments.string_field("command")?,
        }),
        "git_status" => Ok(AgentToolInput::GitStatus),
        "git_diff" => Ok(AgentToolInput::GitDiff),
        "ask_user" => Ok(AgentToolInput::AskUser {
            question: arguments.string_field("question")?,
        }),
        _ => Err(format!(
            "The provider requested an unsupported tool '{name}'."
        )),
    }
}

fn json_string(value: &str) -> String {
    format!("\"{}\"", escape_json(value))
}

fn optional_json_string(value: Option<&str>) -> String {
    value.map_or_else(|| "null".to_owned(), json_string)
}

fn escape_json(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            character if character.is_control() => {
                escaped.push_str(&format!("\\u{:04x}", character as u32));
            }
            character => escaped.push(character),
        }
    }
    escaped
}

#[derive(Clone, Debug)]
enum JsonValue {
    Null,
    Boolean(bool),
    Number(String),
    String(String),
    Array(Vec<Self>),
    Object(BTreeMap<String, Self>),
}

impl JsonValue {
    fn field(&self, field: &str) -> Option<&Self> {
        self.object_value().ok()?.get(field)
    }

    fn optional_string_value(&self, field: &str) -> Option<&str> {
        match self.field(field) {
            Some(Self::String(value)) => Some(value),
            _ => None,
        }
    }

    fn matches_id(&self, expected: &str) -> bool {
        match self.field("id") {
            Some(Self::Number(value)) | Some(Self::String(value)) => value == expected,
            _ => false,
        }
    }

    fn compact_json(&self) -> String {
        match self {
            Self::Null => "null".to_owned(),
            Self::Boolean(value) => value.to_string(),
            Self::Number(value) => value.clone(),
            Self::String(value) => json_string(value),
            Self::Array(values) => format!(
                "[{}]",
                values
                    .iter()
                    .map(Self::compact_json)
                    .collect::<Vec<_>>()
                    .join(",")
            ),
            Self::Object(values) => format!(
                "{{{}}}",
                values
                    .iter()
                    .map(|(key, value)| format!("{}:{}", json_string(key), value.compact_json()))
                    .collect::<Vec<_>>()
                    .join(",")
            ),
        }
    }

    fn object_field(&self, field: &str) -> Result<&Self, String> {
        self.object_value()?
            .get(field)
            .ok_or_else(|| format!("The provider response did not contain '{field}'."))
    }

    fn string_field(&self, field: &str) -> Result<String, String> {
        self.optional_string(field)?
            .ok_or_else(|| format!("The provider response did not contain a string '{field}'."))
    }

    fn optional_string(&self, field: &str) -> Result<Option<String>, String> {
        match self.object_value()?.get(field) {
            None | Some(Self::Null) => Ok(None),
            Some(Self::String(value)) => Ok(Some(value.clone())),
            Some(_) => Err(format!(
                "The provider response field '{field}' was not a string."
            )),
        }
    }

    fn optional_array(&self, field: &str) -> Result<Option<&[Self]>, String> {
        match self.object_value()?.get(field) {
            None | Some(Self::Null) => Ok(None),
            Some(Self::Array(values)) => Ok(Some(values)),
            Some(_) => Err(format!(
                "The provider response field '{field}' was not an array."
            )),
        }
    }

    fn optional_usize(&self, field: &str) -> Result<Option<usize>, String> {
        match self.object_value()?.get(field) {
            None | Some(Self::Null) => Ok(None),
            Some(Self::Number(value)) => value.parse::<usize>().map(Some).map_err(|_| {
                format!("The tool argument '{field}' was not a non-negative integer.")
            }),
            Some(_) => Err(format!("The tool argument '{field}' was not a number.")),
        }
    }

    fn object_value(&self) -> Result<&BTreeMap<String, Self>, String> {
        match self {
            Self::Object(value) => Ok(value),
            _ => Err("Expected a JSON object from the inference provider.".to_owned()),
        }
    }

    fn array_value(&self) -> Option<&[Self]> {
        match self {
            Self::Array(values) => Some(values),
            _ => None,
        }
    }
}

struct JsonParser<'a> {
    bytes: &'a [u8],
    position: usize,
}

impl<'a> JsonParser<'a> {
    fn parse(input: &'a str) -> Result<JsonValue, String> {
        let mut parser = Self {
            bytes: input.as_bytes(),
            position: 0,
        };
        let value = parser.value()?;
        parser.whitespace();
        if parser.position != parser.bytes.len() {
            return Err("Unexpected characters after JSON value.".to_owned());
        }
        Ok(value)
    }

    fn value(&mut self) -> Result<JsonValue, String> {
        self.whitespace();
        match self.peek() {
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'\"') => self.string().map(JsonValue::String),
            Some(b't') => self.literal("true", JsonValue::Boolean(true)),
            Some(b'f') => self.literal("false", JsonValue::Boolean(false)),
            Some(b'n') => self.literal("null", JsonValue::Null),
            Some(b'-' | b'0'..=b'9') => self.number(),
            _ => Err("Expected a JSON value.".to_owned()),
        }
    }

    fn object(&mut self) -> Result<JsonValue, String> {
        self.consume(b'{')?;
        self.whitespace();
        let mut values = BTreeMap::new();
        if self.try_consume(b'}') {
            return Ok(JsonValue::Object(values));
        }
        loop {
            self.whitespace();
            let key = self.string()?;
            self.whitespace();
            self.consume(b':')?;
            let value = self.value()?;
            values.insert(key, value);
            self.whitespace();
            if self.try_consume(b'}') {
                break;
            }
            self.consume(b',')?;
        }
        Ok(JsonValue::Object(values))
    }

    fn array(&mut self) -> Result<JsonValue, String> {
        self.consume(b'[')?;
        self.whitespace();
        let mut values = Vec::new();
        if self.try_consume(b']') {
            return Ok(JsonValue::Array(values));
        }
        loop {
            values.push(self.value()?);
            self.whitespace();
            if self.try_consume(b']') {
                break;
            }
            self.consume(b',')?;
        }
        Ok(JsonValue::Array(values))
    }

    fn string(&mut self) -> Result<String, String> {
        self.consume(b'\"')?;
        let mut value = String::new();
        loop {
            let byte = self
                .next()
                .ok_or_else(|| "Unterminated JSON string.".to_owned())?;
            match byte {
                b'\"' => break,
                b'\\' => match self
                    .next()
                    .ok_or_else(|| "Invalid JSON escape.".to_owned())?
                {
                    b'\"' => value.push('"'),
                    b'\\' => value.push('\\'),
                    b'/' => value.push('/'),
                    b'b' => value.push('\u{0008}'),
                    b'f' => value.push('\u{000c}'),
                    b'n' => value.push('\n'),
                    b'r' => value.push('\r'),
                    b't' => value.push('\t'),
                    b'u' => value.push(self.unicode_escape()?),
                    _ => return Err("Invalid JSON escape sequence.".to_owned()),
                },
                byte if byte < 0x20 => return Err("Control character in JSON string.".to_owned()),
                byte if byte.is_ascii() => value.push(byte as char),
                byte => {
                    let start = self.position - 1;
                    let width = match byte {
                        0xC2..=0xDF => 2,
                        0xE0..=0xEF => 3,
                        0xF0..=0xF4 => 4,
                        _ => return Err("Invalid UTF-8 sequence in JSON string.".to_owned()),
                    };
                    let end = start + width;
                    let character = self
                        .bytes
                        .get(start..end)
                        .and_then(|bytes| std::str::from_utf8(bytes).ok())
                        .ok_or_else(|| "Invalid UTF-8 sequence in JSON string.".to_owned())?;
                    value.push_str(character);
                    self.position = end;
                }
            }
        }
        Ok(value)
    }

    fn unicode_escape(&mut self) -> Result<char, String> {
        let mut value = 0_u32;
        for _ in 0..4 {
            let byte = self
                .next()
                .ok_or_else(|| "Invalid unicode escape.".to_owned())?;
            value = value * 16
                + match byte {
                    b'0'..=b'9' => (byte - b'0') as u32,
                    b'a'..=b'f' => (byte - b'a' + 10) as u32,
                    b'A'..=b'F' => (byte - b'A' + 10) as u32,
                    _ => return Err("Invalid unicode escape.".to_owned()),
                };
        }
        char::from_u32(value).ok_or_else(|| "Invalid unicode escape.".to_owned())
    }

    fn number(&mut self) -> Result<JsonValue, String> {
        let start = self.position;
        while matches!(
            self.peek(),
            Some(b'-' | b'+' | b'.' | b'e' | b'E' | b'0'..=b'9')
        ) {
            self.position += 1;
        }
        let value = std::str::from_utf8(&self.bytes[start..self.position])
            .map_err(|_| "Invalid JSON number.".to_owned())?;
        if value.parse::<f64>().is_err() {
            return Err("Invalid JSON number.".to_owned());
        }
        Ok(JsonValue::Number(value.to_owned()))
    }

    fn literal(&mut self, literal: &str, value: JsonValue) -> Result<JsonValue, String> {
        if self.bytes[self.position..].starts_with(literal.as_bytes()) {
            self.position += literal.len();
            Ok(value)
        } else {
            Err("Invalid JSON literal.".to_owned())
        }
    }

    fn whitespace(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\n' | b'\r' | b'\t')) {
            self.position += 1;
        }
    }

    fn consume(&mut self, byte: u8) -> Result<(), String> {
        if self.try_consume(byte) {
            Ok(())
        } else {
            Err(format!("Expected '{}'.", byte as char))
        }
    }

    fn try_consume(&mut self, byte: u8) -> bool {
        if self.peek() == Some(byte) {
            self.position += 1;
            true
        } else {
            false
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.position).copied()
    }

    fn next(&mut self) -> Option<u8> {
        let byte = self.peek()?;
        self.position += 1;
        Some(byte)
    }
}
