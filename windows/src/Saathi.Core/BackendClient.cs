//
//  BackendClient.cs
//  Saathi.Core
//
//  The only thing that talks to the backend. Provider keys live there and never reach this process.
//  Mirrors macos/Saathi/Sources/SaathiKit/BackendClient.swift.
//

using System.Net.Http.Json;
using System.Text.Json.Serialization;
using Saathi.Contract;

namespace Saathi.Core;

public sealed record BackendHealth(
    [property: JsonPropertyName("ok")] bool Ok,
    [property: JsonPropertyName("version")] string? Version);

public sealed class BackendException : Exception
{
    public BackendException(string message, Exception? inner = null) : base(message, inner) { }
}

public sealed class BackendClient : IDisposable
{
    private readonly Uri _baseUrl;
    private readonly string? _token;
    private readonly HttpClient _http;
    private readonly bool _ownsHttpClient;

    public BackendClient(SaathiConfiguration configuration, HttpClient? httpClient = null)
    {
        if (!Uri.TryCreate(configuration.ResolvedBaseUrl, UriKind.Absolute, out var url))
        {
            throw new BackendException($"{configuration.ResolvedBaseUrl} is not a usable backend URL");
        }

        _baseUrl = url;
        _token = configuration.Token;
        _ownsHttpClient = httpClient is null;
        _http = httpClient ?? new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
    }

    public Task<BackendHealth> HealthAsync(CancellationToken cancellationToken = default) =>
        GetAsync<BackendHealth>("/health", authenticated: false, cancellationToken);

    private async Task<T> GetAsync<T>(string path, bool authenticated, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, new Uri(_baseUrl, path));

        if (authenticated)
        {
            if (string.IsNullOrEmpty(_token))
            {
                throw new BackendException("no token in ~/.saathi/shell.json — sign in first");
            }
            request.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", _token);
        }

        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            throw new BackendException($"could not reach the backend: {e.Message}", e);
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
                // Capped: an upstream error page should not become the whole error message, and a
                // backend is entitled to return something enormous when it is unhappy.
                var excerpt = body.Length > 512 ? body[..512] : body;
                throw new BackendException($"backend returned {(int)response.StatusCode}: {excerpt}");
            }

            try
            {
                var value = await response.Content
                    .ReadFromJsonAsync<T>(cancellationToken)
                    .ConfigureAwait(false);
                return value ?? throw new BackendException("backend returned an empty body");
            }
            catch (System.Text.Json.JsonException e)
            {
                throw new BackendException($"unexpected response shape: {e.Message}", e);
            }
        }
    }

    public void Dispose()
    {
        if (_ownsHttpClient) _http.Dispose();
    }
}
