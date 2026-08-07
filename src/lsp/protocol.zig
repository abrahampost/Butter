//! Struct definitions for the subset of the Language Server Protocol this
//! server implements. Decoded from/encoded to JSON via `std.json`'s
//! reflection-based `parseFromValue`/`Stringify.value` (see rpc.zig) —
//! every field name here is exactly the wire's own camelCase JSON key, so
//! no custom (de)serialization is needed anywhere in this file.

const std = @import("std");
const tokens = @import("tokens.zig");

/// Zero-based line/character. Byte-offset internally; UTF-16 on the wire
/// — see tokens.zig's doc comment.
pub const Position = tokens.Position;

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const DiagnosticSeverity = struct {
    pub const err: u32 = 1;
    pub const warning: u32 = 2;
    pub const information: u32 = 3;
    pub const hint: u32 = 4;
};

pub const Diagnostic = struct {
    range: Range,
    severity: ?u32 = null,
    source: ?[]const u8 = "butter",
    message: []const u8,
};

pub const TextDocumentItem = struct {
    uri: []const u8,
    languageId: []const u8 = "butter",
    version: i64 = 0,
    text: []const u8 = "",
};

pub const TextDocumentIdentifier = struct {
    uri: []const u8,
};

pub const VersionedTextDocumentIdentifier = struct {
    uri: []const u8,
    version: i64 = 0,
};

pub const TextDocumentContentChangeEvent = struct {
    // Full-document sync only (this server declares `textDocumentSync: 1`
    // in its capabilities) — `range`/`rangeLength`, which only a Zig
    // client using incremental sync would send, are simply never present
    // and never looked at.
    text: []const u8,
};

pub const TextDocumentPositionParams = struct {
    textDocument: TextDocumentIdentifier,
    position: Position,
};

pub const InitializeParams = struct {
    rootUri: ?[]const u8 = null,
    rootPath: ?[]const u8 = null,
};

pub const DidOpenTextDocumentParams = struct {
    textDocument: TextDocumentItem,
};

pub const DidChangeTextDocumentParams = struct {
    textDocument: VersionedTextDocumentIdentifier,
    contentChanges: []TextDocumentContentChangeEvent,
};

pub const DidCloseTextDocumentParams = struct {
    textDocument: TextDocumentIdentifier,
};

pub const DidSaveTextDocumentParams = struct {
    textDocument: TextDocumentIdentifier,
};

pub const HoverParams = TextDocumentPositionParams;
pub const DefinitionParams = TextDocumentPositionParams;
pub const CompletionParams = TextDocumentPositionParams;

pub const DocumentSymbolParams = struct {
    textDocument: TextDocumentIdentifier,
};

pub const MarkupContent = struct {
    kind: []const u8 = "markdown",
    value: []const u8,
};

pub const Hover = struct {
    contents: MarkupContent,
    range: ?Range = null,
};

/// LSP `SymbolKind` values this server actually emits (the full enum has
/// many more; only naming the ones symbols.zig/document_symbol.zig use).
pub const SymbolKind = struct {
    pub const function: u32 = 12;
    pub const @"struct": u32 = 23;
    pub const @"enum": u32 = 10;
    pub const enum_member: u32 = 22;
    pub const field: u32 = 8;
    pub const method: u32 = 6;
    pub const variable: u32 = 13;
    pub const constant: u32 = 14;
    pub const module: u32 = 2;
};

pub const DocumentSymbol = struct {
    name: []const u8,
    detail: ?[]const u8 = null,
    kind: u32,
    range: Range,
    selectionRange: Range,
    children: ?[]const DocumentSymbol = null,
};

/// LSP `CompletionItemKind` values this server emits.
pub const CompletionItemKind = struct {
    pub const text: u32 = 1;
    pub const method: u32 = 2;
    pub const function: u32 = 3;
    pub const field: u32 = 5;
    pub const variable: u32 = 6;
    pub const class: u32 = 7; // used for struct types
    pub const module: u32 = 9; // used for import paths
    pub const @"enum": u32 = 13;
    pub const keyword: u32 = 14;
    pub const enum_member: u32 = 20;
};

pub const CompletionItem = struct {
    label: []const u8,
    kind: ?u32 = null,
    detail: ?[]const u8 = null,
    documentation: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
};

pub const PublishDiagnosticsParams = struct {
    uri: []const u8,
    diagnostics: []const Diagnostic,
};

pub const CompletionOptions = struct {
    triggerCharacters: []const []const u8 = &.{"."},
};

pub const ServerCapabilities = struct {
    /// "utf-16" is the only value real clients accept — see tokens.zig's
    /// doc comment.
    positionEncoding: []const u8 = "utf-16",
    /// `TextDocumentSyncKind.Full` — see `TextDocumentContentChangeEvent`'s
    /// doc comment.
    textDocumentSync: u32 = 1,
    hoverProvider: bool = true,
    definitionProvider: bool = true,
    documentSymbolProvider: bool = true,
    completionProvider: CompletionOptions = .{},
};

pub const ServerInfo = struct {
    name: []const u8 = "butter-lsp",
    version: []const u8 = "0.0.1",
};

pub const InitializeResult = struct {
    capabilities: ServerCapabilities = .{},
    serverInfo: ServerInfo = .{},
};
