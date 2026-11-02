#ifndef HOSTSHELL_CORE_H
#define HOSTSHELL_CORE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EngineWrapper EngineWrapper;
typedef struct SessionWrapper SessionWrapper;

typedef void (*StageCallback)(const char *event_json, void *user_data);
typedef void (*OutputCallback)(const uint8_t *data, size_t len, void *user_data);
/* Return response byte count, -1 to cancel, or -2 if the response does not fit. */
typedef int32_t (*AuthInputCallback)(
    const char *name,
    const char *instructions,
    const char *prompt,
    bool echo,
    char *response,
    size_t response_capacity,
    void *user_data
);

EngineWrapper *hostshell_engine_init(void);
void hostshell_engine_free(EngineWrapper *engine);
void hostshell_free_string(char *ptr);

char *hostshell_list_hosts(EngineWrapper *engine);
int hostshell_save_host(EngineWrapper *engine, const char *host_json);
int hostshell_delete_host(EngineWrapper *engine, const char *host_id);

char *hostshell_list_jump_hosts(EngineWrapper *engine);
int hostshell_save_jump_host(EngineWrapper *engine, const char *jh_json);
int hostshell_delete_jump_host(EngineWrapper *engine, const char *jh_id);

char *hostshell_import_ssh_config(EngineWrapper *engine, const char *config_text);

SessionWrapper *hostshell_connect(
    EngineWrapper *engine,
    const char *host_json,
    uint32_t cols,
    uint32_t rows,
    bool auto_accept_new_keys,
    StageCallback stage_cb,
    OutputCallback output_cb,
    void *user_data
);

SessionWrapper *hostshell_connect_with_auth_input(
    EngineWrapper *engine,
    const char *host_json,
    uint32_t cols,
    uint32_t rows,
    bool auto_accept_new_keys,
    StageCallback stage_cb,
    OutputCallback output_cb,
    AuthInputCallback auth_input_cb,
    void *user_data
);

int hostshell_session_write(SessionWrapper *session, const uint8_t *data, size_t len);
int hostshell_session_resize(SessionWrapper *session, uint32_t cols, uint32_t rows);
void hostshell_session_close(SessionWrapper *session);

#ifdef __cplusplus
}
#endif

#endif /* HOSTSHELL_CORE_H */
