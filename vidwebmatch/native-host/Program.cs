using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;

internal static class Program
{
    private const string ProtocolVersion = "1.0";

    public static int Main(string[] args)
    {
        try
        {
            var cli = CliOptions.Parse(args);
            if (cli.ShowHelp)
            {
                Console.Error.WriteLine("VidWebMatch.NativeHost");
                Console.Error.WriteLine("  --host-mode");
                Console.Error.WriteLine("  --options-file <path>");
                Console.Error.WriteLine("  --search-root <path>");
                Console.Error.WriteLine("  --match-extensions .avi,.mp4");
                Console.Error.WriteLine("  --case-insensitive <true|false>");
                Console.Error.WriteLine("  --max-batch-size <int>");
                Console.Error.WriteLine("  --cache-ttl-seconds <int>");
                Console.Error.WriteLine("  --log-path <path>");
                return 0;
            }

            var options = ResolvedOptions.Resolve(cli);
            var logger = new Logger(options.LogPath);
            var engine = new HostEngine(options, logger);

            logger.Info("native_host_start");
            RunHostLoop(engine, logger);
            logger.Info("native_host_stop");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 1;
        }
    }

    private static void RunHostLoop(HostEngine engine, Logger logger)
    {
        using var input = Console.OpenStandardInput();
        using var output = Console.OpenStandardOutput();

        while (NativeMessaging.TryReadMessage(input, out var messageJson))
        {
            if (string.IsNullOrWhiteSpace(messageJson))
            {
                continue;
            }

            string response;
            try
            {
                response = engine.ProcessRequest(messageJson);
            }
            catch (Exception ex)
            {
                logger.Error("request_processing_failed", ex.Message);
                response = JsonSerializer.Serialize(new
                {
                    type = "error",
                    protocol_version = ProtocolVersion,
                    request_id = "",
                    ok = false,
                    error_code = "internal_error",
                    message = ex.Message
                });
            }

            NativeMessaging.WriteMessage(output, response);
        }
    }
}

internal sealed class HostEngine
{
    private readonly ResolvedOptions _options;
    private readonly Logger _logger;
    private readonly object _indexLock = new object();
    private IndexSnapshot? _cachedIndex;
    private DateTimeOffset _cachedAtUtc;

    public HostEngine(ResolvedOptions options, Logger logger)
    {
        _options = options;
        _logger = logger;
    }

    public string ProcessRequest(string requestJson)
    {
        using var doc = JsonDocument.Parse(requestJson);
        var root = doc.RootElement;
        var requestId = GetOptionalString(root, "request_id") ?? string.Empty;
        var requestType = GetOptionalString(root, "type");

        if (string.IsNullOrWhiteSpace(requestType))
        {
            return Error(requestId, "invalid_request", "Request type is required.");
        }

        if (requestType.Equals("ping", StringComparison.OrdinalIgnoreCase))
        {
            return JsonSerializer.Serialize(new
            {
                type = "pong",
                protocol_version = "1.0",
                request_id = requestId,
                ok = true
            });
        }

        if (requestType.Equals("refresh_index", StringComparison.OrdinalIgnoreCase))
        {
            BuildIndex(forceRefresh: true);
            return JsonSerializer.Serialize(new
            {
                type = "refresh_index_result",
                protocol_version = "1.0",
                request_id = requestId,
                ok = true
            });
        }

        if (!requestType.Equals("query_status", StringComparison.OrdinalIgnoreCase))
        {
            return Error(requestId, "invalid_request", $"Unsupported request type: {requestType}");
        }

        if (!root.TryGetProperty("filenames", out var filenamesElement) || filenamesElement.ValueKind != JsonValueKind.Array)
        {
            return Error(requestId, "invalid_request", "filenames must be an array.");
        }

        var filenames = new List<string>();
        foreach (var element in filenamesElement.EnumerateArray())
        {
            if (element.ValueKind == JsonValueKind.String)
            {
                var value = element.GetString();
                if (!string.IsNullOrWhiteSpace(value))
                {
                    filenames.Add(value.Trim());
                }
            }
        }

        if (filenames.Count > _options.MaxBatchSize)
        {
            return Error(requestId, "batch_too_large", "Requested batch exceeds MaxBatchSize.");
        }

        var forceRefresh = GetOptionalBool(root, "force_refresh", false);
        var index = BuildIndex(forceRefresh);
        var results = new List<object>(filenames.Count);

        foreach (var inputName in filenames)
        {
            var baseName = NormalizeBaseName(inputName, _options.CaseInsensitive);
            if (string.IsNullOrWhiteSpace(baseName))
            {
                continue;
            }

            index.ExactLookup.TryGetValue(baseName, out var exactHit);
            var hasAvi = exactHit?.HasAvi ?? false;
            var hasMp4 = exactHit?.HasMp4 ?? false;

            if (!hasAvi && !hasMp4)
            {
                var looseKey = NormalizeLooseMatchKey(baseName);
                if (!string.IsNullOrWhiteSpace(looseKey) && index.LooseLookup.TryGetValue(looseKey, out var looseHit))
                {
                    hasAvi = looseHit.HasAvi;
                    hasMp4 = looseHit.HasMp4;
                }
            }

            var status = "missing";
            if (hasAvi && hasMp4)
            {
                status = "both";
            }
            else if (hasAvi)
            {
                status = "avi_only";
            }
            else if (hasMp4)
            {
                status = "mp4_only";
            }

            results.Add(new
            {
                input = inputName,
                basename = baseName,
                status,
                has_avi = hasAvi,
                has_mp4 = hasMp4
            });
        }

        _logger.Info($"query_status request_id={requestId} requested={filenames.Count} returned={results.Count}");
        return JsonSerializer.Serialize(new
        {
            type = "query_status_result",
            protocol_version = "1.0",
            request_id = requestId,
            ok = true,
            helper_status = "ok",
            search_root = _options.SearchRoot,
            counts = new
            {
                requested = filenames.Count,
                returned = results.Count
            },
            results
        });
    }

    private IndexSnapshot BuildIndex(bool forceRefresh)
    {
        lock (_indexLock)
        {
            var now = DateTimeOffset.UtcNow;
            if (!forceRefresh &&
                _cachedIndex != null &&
                _options.CacheTtlSeconds > 0 &&
                now <= _cachedAtUtc.AddSeconds(_options.CacheTtlSeconds))
            {
                return _cachedIndex;
            }

            var extensionSet = new HashSet<string>(_options.MatchExtensions, StringComparer.OrdinalIgnoreCase);
            var exactLookup = new Dictionary<string, IndexEntry>(_options.CaseInsensitive ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
            var looseLookup = new Dictionary<string, IndexEntry>(_options.CaseInsensitive ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);

            var enumerationOptions = new EnumerationOptions
            {
                RecurseSubdirectories = true,
                IgnoreInaccessible = true,
                AttributesToSkip = FileAttributes.ReparsePoint
            };

            var rootWithSeparator = EnsureTrailingSeparator(Path.GetFullPath(_options.SearchRoot));
            var comparison = _options.CaseInsensitive ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
            var scannedFiles = 0;

            foreach (var filePath in Directory.EnumerateFiles(_options.SearchRoot, "*", enumerationOptions))
            {
                var fullPath = Path.GetFullPath(filePath);
                if (!fullPath.StartsWith(rootWithSeparator, comparison))
                {
                    continue;
                }

                var ext = NormalizeExtension(Path.GetExtension(fullPath));
                if (!extensionSet.Contains(ext))
                {
                    continue;
                }

                var baseName = NormalizeBaseName(fullPath, _options.CaseInsensitive);
                if (string.IsNullOrWhiteSpace(baseName))
                {
                    continue;
                }

                if (!exactLookup.TryGetValue(baseName, out var entry))
                {
                    entry = new IndexEntry();
                    exactLookup[baseName] = entry;
                }

                if (ext.Equals(".avi", StringComparison.OrdinalIgnoreCase))
                {
                    entry.HasAvi = true;
                }
                else if (ext.Equals(".mp4", StringComparison.OrdinalIgnoreCase))
                {
                    entry.HasMp4 = true;
                }

                var looseKey = NormalizeLooseMatchKey(baseName);
                if (!string.IsNullOrWhiteSpace(looseKey))
                {
                    if (!looseLookup.TryGetValue(looseKey, out var looseEntry))
                    {
                        looseEntry = new IndexEntry();
                        looseLookup[looseKey] = looseEntry;
                    }
                    MergeEntry(looseEntry, entry);
                }

                scannedFiles++;
            }

            _cachedIndex = new IndexSnapshot(exactLookup, looseLookup);
            _cachedAtUtc = now;
            _logger.Info($"index_refresh root={_options.SearchRoot} files={scannedFiles} basenames={exactLookup.Count} loose_keys={looseLookup.Count}");
            return _cachedIndex;
        }
    }

    private static string Error(string requestId, string code, string message)
    {
        return JsonSerializer.Serialize(new
        {
            type = "error",
            protocol_version = "1.0",
            request_id = requestId,
            ok = false,
            error_code = code,
            message
        });
    }

    private static string NormalizeExtension(string ext)
    {
        var value = (ext ?? string.Empty).Trim().ToLowerInvariant();
        if (value.Length == 0)
        {
            return value;
        }
        if (!value.StartsWith(".", StringComparison.Ordinal))
        {
            value = "." + value;
        }
        return value;
    }

    private static string NormalizeLooseMatchKey(string baseName)
    {
        if (string.IsNullOrWhiteSpace(baseName))
        {
            return string.Empty;
        }

        var chars = new StringBuilder(baseName.Length);
        foreach (var c in baseName)
        {
            if (c == '.' || c == '-' || c == '_' || char.IsWhiteSpace(c))
            {
                continue;
            }
            chars.Append(char.ToLowerInvariant(c));
        }

        return chars.ToString();
    }

    private static void MergeEntry(IndexEntry target, IndexEntry source)
    {
        if (source.HasAvi)
        {
            target.HasAvi = true;
        }
        if (source.HasMp4)
        {
            target.HasMp4 = true;
        }
    }

    private static string? GetOptionalString(JsonElement root, string propertyName)
    {
        if (!root.TryGetProperty(propertyName, out var element))
        {
            return null;
        }
        if (element.ValueKind != JsonValueKind.String)
        {
            return null;
        }
        return element.GetString();
    }

    private static bool GetOptionalBool(JsonElement root, string propertyName, bool fallback)
    {
        if (!root.TryGetProperty(propertyName, out var element))
        {
            return fallback;
        }
        if (element.ValueKind == JsonValueKind.True)
        {
            return true;
        }
        if (element.ValueKind == JsonValueKind.False)
        {
            return false;
        }
        return fallback;
    }

    private static string NormalizeBaseName(string input, bool caseInsensitive)
    {
        var leaf = Path.GetFileName(input ?? string.Empty);
        var baseName = Path.GetFileNameWithoutExtension(leaf);
        if (string.IsNullOrWhiteSpace(baseName))
        {
            return string.Empty;
        }
        baseName = baseName.Trim();
        return caseInsensitive ? baseName.ToLowerInvariant() : baseName;
    }

    private static string EnsureTrailingSeparator(string path)
    {
        if (path.EndsWith("\\", StringComparison.Ordinal) || path.EndsWith("/", StringComparison.Ordinal))
        {
            return path;
        }
        return path + Path.DirectorySeparatorChar;
    }
}

internal sealed class IndexSnapshot
{
    public Dictionary<string, IndexEntry> ExactLookup { get; }
    public Dictionary<string, IndexEntry> LooseLookup { get; }

    public IndexSnapshot(Dictionary<string, IndexEntry> exactLookup, Dictionary<string, IndexEntry> looseLookup)
    {
        ExactLookup = exactLookup;
        LooseLookup = looseLookup;
    }
}

internal sealed class IndexEntry
{
    public bool HasAvi { get; set; }
    public bool HasMp4 { get; set; }
}

internal sealed class Logger
{
    private readonly string? _path;
    private readonly object _lock = new object();

    public Logger(string? path)
    {
        _path = string.IsNullOrWhiteSpace(path) ? null : path;
    }

    public void Info(string message) => Write("INFO", message);
    public void Error(string eventCode, string details) => Write("ERROR", $"{eventCode} {details}");

    private void Write(string level, string message)
    {
        if (_path == null)
        {
            return;
        }

        try
        {
            var parent = Path.GetDirectoryName(_path);
            if (!string.IsNullOrWhiteSpace(parent))
            {
                Directory.CreateDirectory(parent);
            }

            var line = $"[{DateTimeOffset.UtcNow:yyyy-MM-dd HH:mm:ss}] [{level}] {message}";
            lock (_lock)
            {
                File.AppendAllText(_path, line + Environment.NewLine, Encoding.UTF8);
            }
        }
        catch
        {
            // Logging must not break helper runtime.
        }
    }
}

internal sealed class CliOptions
{
    public bool ShowHelp { get; private set; }
    public string? OptionsFile { get; private set; }
    public string? SearchRoot { get; private set; }
    public string? MatchExtensionsRaw { get; private set; }
    public bool? CaseInsensitive { get; private set; }
    public int? MaxBatchSize { get; private set; }
    public int? CacheTtlSeconds { get; private set; }
    public string? LogPath { get; private set; }

    public static CliOptions Parse(string[] args)
    {
        var result = new CliOptions();
        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            if (arg.Equals("--help", StringComparison.OrdinalIgnoreCase) || arg.Equals("-h", StringComparison.OrdinalIgnoreCase))
            {
                result.ShowHelp = true;
                continue;
            }

            if (!arg.StartsWith("--", StringComparison.Ordinal))
            {
                continue;
            }

            var key = arg.ToLowerInvariant();
            var value = i + 1 < args.Length ? args[i + 1] : null;

            if (key == "--host-mode")
            {
                continue;
            }

            if (value == null || value.StartsWith("--", StringComparison.Ordinal))
            {
                throw new InvalidOperationException($"Missing value for {arg}");
            }

            i++;
            switch (key)
            {
                case "--options-file":
                    result.OptionsFile = value;
                    break;
                case "--search-root":
                    result.SearchRoot = value;
                    break;
                case "--match-extensions":
                    result.MatchExtensionsRaw = value;
                    break;
                case "--case-insensitive":
                    result.CaseInsensitive = ParseBool(value, "--case-insensitive");
                    break;
                case "--max-batch-size":
                    result.MaxBatchSize = ParseInt(value, "--max-batch-size");
                    break;
                case "--cache-ttl-seconds":
                    result.CacheTtlSeconds = ParseInt(value, "--cache-ttl-seconds");
                    break;
                case "--log-path":
                    result.LogPath = value;
                    break;
                default:
                    throw new InvalidOperationException($"Unknown argument: {arg}");
            }
        }

        return result;
    }

    private static bool ParseBool(string value, string name)
    {
        if (bool.TryParse(value, out var parsed))
        {
            return parsed;
        }
        throw new InvalidOperationException($"Invalid boolean for {name}: {value}");
    }

    private static int ParseInt(string value, string name)
    {
        if (int.TryParse(value, out var parsed))
        {
            return parsed;
        }
        throw new InvalidOperationException($"Invalid integer for {name}: {value}");
    }
}

internal sealed class ResolvedOptions
{
    public string SearchRoot { get; set; } = string.Empty;
    public string[] MatchExtensions { get; set; } = Array.Empty<string>();
    public bool CaseInsensitive { get; set; }
    public int MaxBatchSize { get; set; }
    public int CacheTtlSeconds { get; set; }
    public string? LogPath { get; set; }

    public static ResolvedOptions Resolve(CliOptions cli)
    {
        var defaults = new
        {
            MatchExtensions = new[] { ".avi", ".mp4" },
            CaseInsensitive = true,
            MaxBatchSize = 200,
            CacheTtlSeconds = 30,
            LogPath = Path.Combine(AppContext.BaseDirectory, "logs", "native-host.log")
        };

        var optionsFileExplicit = !string.IsNullOrWhiteSpace(cli.OptionsFile);
        var optionsFilePath = optionsFileExplicit
            ? cli.OptionsFile!
            : ResolveDefaultOptionsPath();

        FileOptions? fileOptions = null;
        if (File.Exists(optionsFilePath))
        {
            var raw = File.ReadAllText(optionsFilePath, Encoding.UTF8);
            if (!string.IsNullOrWhiteSpace(raw))
            {
                fileOptions = JsonSerializer.Deserialize<FileOptions>(raw, new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                });
            }
        }
        else if (optionsFileExplicit)
        {
            throw new InvalidOperationException($"Options file not found: {optionsFilePath}");
        }

        var searchRoot = FirstNonEmpty(cli.SearchRoot, fileOptions?.SearchRoot);
        if (string.IsNullOrWhiteSpace(searchRoot))
        {
            throw new InvalidOperationException("SearchRoot is required. Set it in options.json or pass --search-root.");
        }

        var resolvedRoot = Path.GetFullPath(searchRoot);
        if (!Directory.Exists(resolvedRoot))
        {
            throw new InvalidOperationException($"SearchRoot does not exist: {resolvedRoot}");
        }

        var matchExtensions = ParseExtensions(cli.MatchExtensionsRaw)
            ?? NormalizeExtensions(fileOptions?.MatchExtensions)
            ?? defaults.MatchExtensions;
        if (matchExtensions.Length == 0)
        {
            throw new InvalidOperationException("MatchExtensions must contain at least one extension.");
        }

        var caseInsensitive = cli.CaseInsensitive
            ?? fileOptions?.CaseInsensitive
            ?? defaults.CaseInsensitive;

        var maxBatchSize = cli.MaxBatchSize
            ?? fileOptions?.MaxBatchSize
            ?? defaults.MaxBatchSize;
        if (maxBatchSize < 1)
        {
            throw new InvalidOperationException("MaxBatchSize must be >= 1.");
        }

        var cacheTtlSeconds = cli.CacheTtlSeconds
            ?? fileOptions?.CacheTtlSeconds
            ?? defaults.CacheTtlSeconds;
        if (cacheTtlSeconds < 0)
        {
            throw new InvalidOperationException("CacheTtlSeconds must be >= 0.");
        }

        var logPath = FirstNonEmpty(cli.LogPath, fileOptions?.LogPath, defaults.LogPath);
        if (!string.IsNullOrWhiteSpace(logPath))
        {
            logPath = Path.GetFullPath(logPath);
        }

        return new ResolvedOptions
        {
            SearchRoot = resolvedRoot,
            MatchExtensions = matchExtensions,
            CaseInsensitive = caseInsensitive,
            MaxBatchSize = maxBatchSize,
            CacheTtlSeconds = cacheTtlSeconds,
            LogPath = logPath
        };
    }

    private static string ResolveDefaultOptionsPath()
    {
        var baseDir = AppContext.BaseDirectory;
        var candidates = new List<string>
        {
            Path.Combine(baseDir, "options.json")
        };

        var parent = Directory.GetParent(baseDir);
        for (var i = 0; i < 5 && parent != null; i++, parent = parent.Parent)
        {
            candidates.Add(Path.Combine(parent.FullName, "options.json"));
        }

        foreach (var candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        return candidates[0];
    }

    private static string? FirstNonEmpty(params string?[] values)
    {
        foreach (var value in values)
        {
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }
        return null;
    }

    private static string[]? ParseExtensions(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            return null;
        }
        var parts = raw.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries);
        for (var i = 0; i < parts.Length; i++)
        {
            parts[i] = parts[i].Trim();
        }
        return NormalizeExtensions(parts);
    }

    private static string[]? NormalizeExtensions(IEnumerable<string>? values)
    {
        if (values == null)
        {
            return null;
        }

        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in values)
        {
            if (string.IsNullOrWhiteSpace(item))
            {
                continue;
            }
            var ext = item.Trim().ToLowerInvariant();
            if (!ext.StartsWith(".", StringComparison.Ordinal))
            {
                ext = "." + ext;
            }
            set.Add(ext);
        }

        return set.ToArray();
    }

    private sealed class FileOptions
    {
        public string? SearchRoot { get; set; }
        public string[]? MatchExtensions { get; set; }
        public bool? CaseInsensitive { get; set; }
        public int? MaxBatchSize { get; set; }
        public int? CacheTtlSeconds { get; set; }
        public string? LogPath { get; set; }
    }
}

internal static class NativeMessaging
{
    public static bool TryReadMessage(Stream input, out string message)
    {
        message = string.Empty;
        var lengthBytes = new byte[4];
        var read = ReadExactly(input, lengthBytes, 0, 4);
        if (read == 0)
        {
            return false;
        }
        if (read < 4)
        {
            throw new InvalidOperationException("Unexpected EOF while reading native message length.");
        }

        var length = BitConverter.ToInt32(lengthBytes, 0);
        if (length < 0 || length > 16 * 1024 * 1024)
        {
            throw new InvalidOperationException($"Invalid native message length: {length}");
        }

        var payload = new byte[length];
        var payloadRead = ReadExactly(input, payload, 0, length);
        if (payloadRead < length)
        {
            throw new InvalidOperationException("Unexpected EOF while reading native message payload.");
        }

        message = Encoding.UTF8.GetString(payload);
        return true;
    }

    public static void WriteMessage(Stream output, string message)
    {
        var payload = Encoding.UTF8.GetBytes(message ?? "{}");
        var lengthBytes = BitConverter.GetBytes(payload.Length);
        output.Write(lengthBytes, 0, lengthBytes.Length);
        output.Write(payload, 0, payload.Length);
        output.Flush();
    }

    private static int ReadExactly(Stream stream, byte[] buffer, int offset, int count)
    {
        var total = 0;
        while (total < count)
        {
            var n = stream.Read(buffer, offset + total, count - total);
            if (n == 0)
            {
                break;
            }
            total += n;
        }
        return total;
    }
}
