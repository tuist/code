//! Headless, provider-neutral coding-agent loop.
//!
//! A platform user interface can render [`AgentEvent`] values, but it never
//! owns the loop. A command-line runner can provide a model transport and an
//! approval policy directly, using exactly the same Rust implementation.

use std::path::{Path, PathBuf};

use crate::{AgentTool, AgentToolError, AgentToolRequest, AgentToolResult, execute_agent_tool};

/// Configuration for one agent run in a Git worktree.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentRunConfiguration {
    pub worktree: PathBuf,
    pub system_prompt: String,
    pub user_prompt: String,
    pub maximum_turns: usize,
}

impl AgentRunConfiguration {
    pub fn new(
        worktree: impl Into<PathBuf>,
        system_prompt: impl Into<String>,
        user_prompt: impl Into<String>,
    ) -> Self {
        Self {
            worktree: worktree.into(),
            system_prompt: system_prompt.into(),
            user_prompt: user_prompt.into(),
            maximum_turns: 30,
        }
    }
}

/// A provider request created by the shared loop.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentModelRequest {
    pub messages: Vec<AgentMessage>,
    pub tools: Vec<AgentTool>,
}

/// A message in a provider-neutral agent conversation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentMessage {
    System(String),
    User(String),
    Assistant {
        content: Option<String>,
        tool_calls: Vec<AgentToolCall>,
    },
    Tool {
        call_id: String,
        content: String,
    },
}

/// A provider-normalized tool call.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentToolCall {
    pub id: String,
    pub input: AgentToolInput,
}

/// The typed arguments accepted by one shared tool.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentToolInput {
    Read {
        path: String,
        offset: usize,
        limit: usize,
    },
    List {
        path: String,
    },
    Ls {
        path: String,
    },
    Glob {
        pattern: String,
    },
    Find {
        pattern: String,
    },
    Grep {
        pattern: String,
    },
    Write {
        path: String,
        content: String,
    },
    Edit {
        path: String,
        old_text: String,
        new_text: String,
    },
    ApplyPatch {
        patch: String,
    },
    Shell {
        command: String,
    },
    Bash {
        command: String,
    },
    GitStatus,
    GitDiff,
    AskUser {
        question: String,
    },
}

impl AgentToolInput {
    pub const fn tool(&self) -> AgentTool {
        match self {
            Self::Read { .. } => AgentTool::Read,
            Self::List { .. } => AgentTool::List,
            Self::Ls { .. } => AgentTool::Ls,
            Self::Glob { .. } => AgentTool::Glob,
            Self::Find { .. } => AgentTool::Find,
            Self::Grep { .. } => AgentTool::Grep,
            Self::Write { .. } => AgentTool::Write,
            Self::Edit { .. } => AgentTool::Edit,
            Self::ApplyPatch { .. } => AgentTool::ApplyPatch,
            Self::Shell { .. } => AgentTool::Shell,
            Self::Bash { .. } => AgentTool::Bash,
            Self::GitStatus => AgentTool::GitStatus,
            Self::GitDiff => AgentTool::GitDiff,
            Self::AskUser { .. } => AgentTool::AskUser,
        }
    }

    fn as_request(&self) -> AgentToolRequest<'_> {
        match self {
            Self::Read {
                path,
                offset,
                limit,
            } => AgentToolRequest::Read {
                path,
                offset: *offset,
                limit: *limit,
            },
            Self::List { path } | Self::Ls { path } => AgentToolRequest::List { path },
            Self::Glob { pattern } | Self::Find { pattern } => AgentToolRequest::Glob { pattern },
            Self::Grep { pattern } => AgentToolRequest::Grep { pattern },
            Self::Write { path, content } => AgentToolRequest::Write { path, content },
            Self::Edit {
                path,
                old_text,
                new_text,
            } => AgentToolRequest::Edit {
                path,
                old_text,
                new_text,
            },
            Self::ApplyPatch { patch } => AgentToolRequest::ApplyPatch { patch },
            Self::Shell { command } | Self::Bash { command } => AgentToolRequest::Shell { command },
            Self::GitStatus => AgentToolRequest::GitStatus,
            Self::GitDiff => AgentToolRequest::GitDiff,
            Self::AskUser { question } => AgentToolRequest::AskUser { question },
        }
    }

    pub fn summary(&self) -> String {
        match self {
            Self::Read { path, .. }
            | Self::List { path }
            | Self::Ls { path }
            | Self::Write { path, .. }
            | Self::Edit { path, .. } => path.clone(),
            Self::Glob { pattern } | Self::Find { pattern } | Self::Grep { pattern } => {
                pattern.clone()
            }
            Self::ApplyPatch { .. } => "Apply a patch".to_owned(),
            Self::Shell { command } | Self::Bash { command } => command.clone(),
            Self::GitStatus => "Git status".to_owned(),
            Self::GitDiff => "Git diff".to_owned(),
            Self::AskUser { question } => question.clone(),
        }
    }
}

/// A normalized response supplied by an inference provider adapter.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentModelResponse {
    pub content: Option<String>,
    pub tool_calls: Vec<AgentToolCall>,
}

/// A transport implemented by an inference-provider adapter.
pub trait AgentModel {
    type Error: std::fmt::Display;

    fn complete(&mut self, request: &AgentModelRequest) -> Result<AgentModelResponse, Self::Error>;
}

/// The interaction boundary that lets a headless process or a graphical client
/// control mutations and answer questions.
pub trait AgentInteraction {
    fn approve(&mut self, call: &AgentToolCall) -> bool;
    fn answer(&mut self, question: &str) -> Option<String>;
}

/// Incremental events emitted by the Rust loop.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentEvent {
    ModelRequest {
        turn: usize,
    },
    AssistantMessage(String),
    ApprovalRequested {
        tool: AgentTool,
        summary: String,
    },
    ToolCompleted {
        tool: AgentTool,
        output: String,
    },
    ToolFailed {
        tool: AgentTool,
        error: AgentToolError,
    },
    UserQuestion(String),
    Completed,
}

/// A recoverable failure from the headless agent runtime.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AgentLoopError {
    Model(String),
    MaximumTurnsReached,
}

/// Runs a complete provider-neutral agent conversation.
///
/// The model adapter performs only provider transport and response decoding.
/// Tool routing, approval handling, message history, turn limits, and working
/// directory boundaries remain in Rust and therefore work without any app.
pub fn run_agent<M: AgentModel, I: AgentInteraction, F: FnMut(AgentEvent)>(
    configuration: AgentRunConfiguration,
    model: &mut M,
    interaction: &mut I,
    mut emit: F,
) -> Result<Vec<AgentMessage>, AgentLoopError> {
    let mut messages = vec![
        AgentMessage::System(configuration.system_prompt),
        AgentMessage::User(configuration.user_prompt),
    ];

    for turn in 1..=configuration.maximum_turns {
        emit(AgentEvent::ModelRequest { turn });
        let response = model
            .complete(&AgentModelRequest {
                messages: messages.clone(),
                tools: crate::agent_tools().to_vec(),
            })
            .map_err(|error| AgentLoopError::Model(error.to_string()))?;

        if let Some(content) = response
            .content
            .clone()
            .filter(|content| !content.is_empty())
        {
            emit(AgentEvent::AssistantMessage(content));
        }
        messages.push(AgentMessage::Assistant {
            content: response.content,
            tool_calls: response.tool_calls.clone(),
        });

        if response.tool_calls.is_empty() {
            emit(AgentEvent::Completed);
            return Ok(messages);
        }

        for call in response.tool_calls {
            let tool = call.input.tool();
            if tool.requires_approval() {
                emit(AgentEvent::ApprovalRequested {
                    tool,
                    summary: call.input.summary(),
                });
                if !interaction.approve(&call) {
                    messages.push(AgentMessage::Tool {
                        call_id: call.id,
                        content: "The user denied this operation.".to_owned(),
                    });
                    continue;
                }
            }

            if let AgentToolInput::AskUser { question } = &call.input {
                emit(AgentEvent::UserQuestion(question.clone()));
                let answer = interaction
                    .answer(question)
                    .unwrap_or_else(|| "The user did not provide an answer.".to_owned());
                messages.push(AgentMessage::Tool {
                    call_id: call.id,
                    content: answer,
                });
                continue;
            }

            match execute_agent_tool(Path::new(&configuration.worktree), call.input.as_request()) {
                Ok(AgentToolResult::Output(output)) => {
                    emit(AgentEvent::ToolCompleted {
                        tool,
                        output: output.clone(),
                    });
                    messages.push(AgentMessage::Tool {
                        call_id: call.id,
                        content: output,
                    });
                }
                Ok(AgentToolResult::NeedsUserInput(question)) => {
                    emit(AgentEvent::UserQuestion(question.clone()));
                    let answer = interaction
                        .answer(&question)
                        .unwrap_or_else(|| "The user did not provide an answer.".to_owned());
                    messages.push(AgentMessage::Tool {
                        call_id: call.id,
                        content: answer,
                    });
                }
                Err(error) => {
                    emit(AgentEvent::ToolFailed { tool, error });
                    messages.push(AgentMessage::Tool {
                        call_id: call.id,
                        content: format!("Tool failed: {error:?}"),
                    });
                }
            }
        }
    }

    Err(AgentLoopError::MaximumTurnsReached)
}
