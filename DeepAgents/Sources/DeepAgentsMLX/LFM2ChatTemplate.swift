import DeepAgents
import Foundation

// `canonical` below is byte-for-byte the upstream Jinja template; wrapping its long lines
// would change what gets compared against (and written into) the model cache.
// swiftlint:disable line_length

/// The canonical LFM2.5 / LFM2.5-VL chat template, as published by LiquidAI (identical
/// across the family — e.g. `LiquidAI/LFM2.5-VL-450M-MLX-bf16` ships exactly this). Some
/// community MLX conversions (notably `mlx-community/LFM2.5-VL-1.6B-8bit`) ship a stale
/// `chat_template.jinja` that omits the `render_tool_calls` macro: it can inject the tool
/// list into the system prompt but cannot render an assistant turn's `tool_calls` back into
/// history, so after the model's first tool call the call vanishes from the prompt and the
/// loop's tool use falls apart. It also drops LFM2.5's trained `Today's date: …` framing.
/// `MlxModelManager` rewrites a stale cached template to this one before loading the model.
///
/// Verbatim from the upstream file (raw string preserves the Jinja `\n` escapes exactly);
/// do not reformat. swift-jinja honors the `{% generation %}` span markers and
/// `strftime_now`.
public enum LFM2ChatTemplate {
    /// `true` once `template` is present and renders assistant tool calls (the marker the
    /// stale community template lacks).
    static func rendersToolCalls(_ template: String?) -> Bool {
        template?.contains("render_tool_calls") ?? false
    }

    static let canonical = #"""
    {{- bos_token -}}
    {%- set keep_past_thinking = keep_past_thinking | default(false) -%}

    {%- macro format_arg_value(arg_value) -%}
        {%- if arg_value is string -%}
            {{- '"' + arg_value + '"' -}}
        {%- elif arg_value is mapping -%}
            {{- arg_value | tojson -}}
        {%- else -%}
            {{- arg_value | string -}}
        {%- endif -%}
    {%- endmacro -%}

    {%- macro parse_content(content) -%}
        {%- if content is string -%}
            {{- content -}}
        {%- else -%}
            {%- set _ns = namespace(result="") -%}
            {%- for item in content -%}
                {%- if item.type == "image" -%}
                    {%- set _ns.result = _ns.result + "<image>" -%}
                {%- elif item.type == "text" -%}
                    {%- set _ns.result = _ns.result + item.text -%}
                {%- else -%}
                    {%- set _ns.result = _ns.result + item | tojson -%}
                {%- endif -%}
            {%- endfor -%}
            {{- _ns.result -}}
        {%- endif -%}
    {%- endmacro -%}

    {%- macro render_tool_calls(tool_calls) -%}
        {%- set tool_calls_ns = namespace(tool_calls=[]) -%}
        {%- for tool_call in tool_calls -%}
            {%- set func_name = tool_call.function.name -%}
            {%- set func_args = tool_call.function.arguments -%}
            {%- set args_ns = namespace(arg_strings=[]) -%}
            {%- for arg_name, arg_value in func_args.items() -%}
                {%- set args_ns.arg_strings = args_ns.arg_strings + [arg_name + "=" + format_arg_value(arg_value)] -%}
            {%- endfor -%}
            {%- set tool_calls_ns.tool_calls = tool_calls_ns.tool_calls + [func_name + "(" + (args_ns.arg_strings | join(", ")) + ")"] -%}
        {%- endfor -%}
        {{- "<|tool_call_start|>[" + (tool_calls_ns.tool_calls | join(", ")) + "]<|tool_call_end|>" -}}
    {%- endmacro -%}

    {%- set ns = namespace(system_prompt="", last_assistant_index=-1) -%}
    {%- if messages[0].role == "system" -%}
        {%- if messages[0].content is defined -%}
            {%- set ns.system_prompt = parse_content(messages[0].content) -%}
        {%- endif -%}
        {%- set messages = messages[1:] -%}
    {%- endif -%}
    {%- if tools -%}
        {%- set ns.system_prompt = ns.system_prompt + ("\n\n" if ns.system_prompt else "") + "Today's date: " + strftime_now("%Y-%m-%d") + "\n\nList of tools: " + (tools | tojson) -%}
    {%- endif -%}
    {%- if ns.system_prompt -%}
        {{- "<|im_start|>system\n" + ns.system_prompt + "<|im_end|>\n" -}}
    {%- endif -%}
    {%- for message in messages -%}
        {%- if message.role == "assistant" -%}
            {%- set ns.last_assistant_index = loop.index0 -%}
        {%- endif -%}
    {%- endfor -%}
    {%- for message in messages -%}
        {{- "<|im_start|>" + message.role + "\n" -}}
        {%- if message.role == "assistant" -%}
            {%- generation -%}
            {%- if message.thinking is defined and (keep_past_thinking or loop.index0 == ns.last_assistant_index) -%}
                {{- "<think>" + message.thinking + "</think>" -}}
            {%- endif -%}
            {%- if message.tool_calls is defined -%}
                {{- render_tool_calls(message.tool_calls) -}}
            {%- endif -%}
            {%- if message.content is defined -%}
                {%- set content = parse_content(message.content) -%}
                {%- if not keep_past_thinking and loop.index0 != ns.last_assistant_index -%}
                    {%- if "</think>" in content -%}
                        {%- set content = content.split("</think>")[-1] | trim -%}
                    {%- endif -%}
                {%- endif -%}
                {{- content + ("" if (continue_final_message and loop.last) else "<|im_end|>\n") -}}
            {%- endif -%}
            {%- endgeneration -%}
        {%- else %}
            {%- if message.content is defined -%}
                {{- parse_content(message.content) + "<|im_end|>\n" -}}
            {%- endif -%}
        {%- endif %}
    {%- endfor -%}
    {%- if add_generation_prompt -%}
        {{- "<|im_start|>assistant\n" -}}
    {%- endif -%}
    """#
}

// swiftlint:enable line_length
