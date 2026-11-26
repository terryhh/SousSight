package dev.soussight.ai_logic_hybrid

import com.google.firebase.ai.type.Schema

/**
 * DESIGN §4 JSON Schema subset (type, properties, required, items, enum, minItems, maxItems,
 * description; lowercase types) to the SDK's [Schema], used as the cloud `responseSchema`.
 * Anything outside the subset is `unsupportedInput`, raised before any SDK call.
 */
object SchemaMapping {
    private val allowedKeys = setOf(
        "type", "properties", "required", "items", "enum", "minItems", "maxItems", "description",
    )

    fun toSchema(json: Map<String, Any?>, path: String = "$"): Schema {
        val unknown = json.keys - allowedKeys
        if (unknown.isNotEmpty()) unsupported("$path: unsupported schema keys $unknown")
        val description = json["description"]?.let {
            it as? String ?: unsupported("$path.description must be a string")
        }
        val enum = json["enum"]?.let { raw ->
            (raw as? List<*>)?.map { it as? String ?: unsupported("$path.enum must hold strings") }
                ?: unsupported("$path.enum must be a list")
        }
        return when (val type = json["type"]) {
            "object" -> {
                val props = json["properties"] as? Map<*, *>
                    ?: unsupported("$path: object needs properties")
                val properties = props.entries.associate { (k, v) ->
                    val key = k as? String ?: unsupported("$path: property names must be strings")
                    @Suppress("UNCHECKED_CAST")
                    val child = v as? Map<String, Any?>
                        ?: unsupported("$path.$key must be a schema")
                    key to toSchema(child, "$path.$key")
                }
                val required = (json["required"] as? List<*>)?.map {
                    it as? String ?: unsupported("$path.required must hold strings")
                } ?: emptyList()
                val missing = required - properties.keys
                if (missing.isNotEmpty()) unsupported("$path: required names unknown properties $missing")
                Schema.obj(
                    properties = properties,
                    optionalProperties = properties.keys.filter { it !in required },
                    description = description,
                )
            }
            "array" -> {
                @Suppress("UNCHECKED_CAST")
                val items = json["items"] as? Map<String, Any?>
                    ?: unsupported("$path: array needs items")
                Schema.array(
                    items = toSchema(items, "$path[]"),
                    description = description,
                    minItems = (json["minItems"] as? Number)?.toInt(),
                    maxItems = (json["maxItems"] as? Number)?.toInt(),
                )
            }
            "string" ->
                if (enum != null) Schema.enumeration(enum, description)
                else Schema.string(description)
            "integer" -> Schema.integer(description)
            "number" -> Schema.double(description)
            "boolean" -> Schema.boolean(description)
            else -> unsupported("$path: unsupported type $type")
        }.also {
            if (enum != null && json["type"] != "string") {
                unsupported("$path: enum is only supported on strings")
            }
        }
    }

    /**
     * Text appended to the prompt when the request may run locally. The SDK does not forward a
     * manual schema to the on-device model, so the caller still validates the output.
     */
    fun localInstruction(json: Map<String, Any?>): String =
        "Reply with only a JSON value, without prose or code fences, that matches this " +
            "JSON Schema: ${JsonText.encode(json)}"

    private fun unsupported(message: String): Nothing =
        throw HybridError(HybridErrorCode.UNSUPPORTED_INPUT, "jsonSchema $message")
}

/** Compact JSON like Dart's jsonEncode, so the token estimate matches the Dart policy. */
object JsonText {
    fun encode(value: Any?): String = StringBuilder().also { write(it, value) }.toString()

    private fun write(out: StringBuilder, value: Any?) {
        when (value) {
            null -> out.append("null")
            is String -> writeString(out, value)
            is Boolean -> out.append(value)
            is Int, is Long, is Short, is Byte -> out.append(value)
            is Number -> {
                val d = value.toDouble()
                if (d.isNaN() || d.isInfinite()) {
                    throw HybridError(HybridErrorCode.UNSUPPORTED_INPUT, "Non-finite number in JSON")
                }
                out.append(d)
            }
            is Map<*, *> -> {
                out.append('{')
                var first = true
                for ((k, v) in value) {
                    if (!first) out.append(',')
                    first = false
                    writeString(out, k.toString())
                    out.append(':')
                    write(out, v)
                }
                out.append('}')
            }
            is List<*> -> {
                out.append('[')
                value.forEachIndexed { i, v ->
                    if (i > 0) out.append(',')
                    write(out, v)
                }
                out.append(']')
            }
            else -> writeString(out, value.toString())
        }
    }

    private fun writeString(out: StringBuilder, s: String) {
        out.append('"')
        for (c in s) {
            when (c) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (c < ' ') out.append(String.format("\\u%04x", c.code)) else out.append(c)
            }
        }
        out.append('"')
    }
}
