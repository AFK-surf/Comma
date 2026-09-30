export const defaultImageConfig = `{
  "provider": "",
  "model": "",
  "provider_config": {
    "base_url": "",
    "api_key_env": ""
  }
}`;

export const openAIImageConfigExample = `{
  "provider": "openai",
  "model": "gpt-image-2",
  "provider_config": {
    "base_url": "https://api.openai.com/v1",
    "api_key_env": "OPENAI_IMAGE_API_KEY"
  }
}`;

export const geminiImageConfigExample = `{
  "provider": "gemini",
  "model": "gemini-3-pro-image-preview",
  "provider_config": {
    "base_url": "https://generativelanguage.googleapis.com/v1beta",
    "api_key_env": "GEMINI_IMAGE_API_KEY"
  }
}`;
