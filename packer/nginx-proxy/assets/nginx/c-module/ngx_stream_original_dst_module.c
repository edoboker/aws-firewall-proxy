/*
 * ngx_stream_original_dst_module
 *
 * Exposes $original_dst as a stream variable containing the pre-NAT
 * destination address of the downstream connection, as recovered via
 * getsockopt(SO_ORIGINAL_DST). Only meaningful when traffic reaches
 * nginx via iptables REDIRECT/DNAT. Linux-only.
 *
 * Format: "AAA.BBB.CCC.DDD:PORT"  (IPv4 only for this spike)
 *
 * This module deliberately contains no policy logic. It only surfaces
 * the kernel-recorded original destination so that downstream Lua code
 * can perform the SNI-vs-resolved-IP comparison.
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_stream.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/netfilter_ipv4.h>


static ngx_int_t ngx_stream_original_dst_variable(ngx_stream_session_t *s, ngx_stream_variable_value_t *v, uintptr_t data);
static ngx_int_t ngx_stream_original_dst_add_variables(ngx_conf_t *cf);


static ngx_stream_module_t  ngx_stream_original_dst_module_ctx = {
    ngx_stream_original_dst_add_variables, /* preconfiguration */
    NULL,                                  /* postconfiguration */
    NULL, NULL, NULL, NULL
};


ngx_module_t  ngx_stream_original_dst_module = {
    NGX_MODULE_V1,
    &ngx_stream_original_dst_module_ctx,   /* module context */
    NULL,                                  /* module directives */
    NGX_STREAM_MODULE,                     /* module type */
    NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NGX_MODULE_V1_PADDING
};


static ngx_str_t  ngx_stream_original_dst_name = ngx_string("original_dst");


static ngx_int_t
ngx_stream_original_dst_add_variables(ngx_conf_t *cf)
{
    ngx_stream_variable_t  *var;

    var = ngx_stream_add_variable(cf, &ngx_stream_original_dst_name, 0);
    if (var == NULL) {
        return NGX_ERROR;
    }

    var->get_handler = ngx_stream_original_dst_variable;
    return NGX_OK;
}


static ngx_int_t
ngx_stream_original_dst_variable(ngx_stream_session_t *s,
    ngx_stream_variable_value_t *v, uintptr_t data)
{
    struct sockaddr_storage  ss;
    socklen_t                sslen = sizeof(ss);
    ngx_connection_t        *c = s->connection;
    u_char                  *buf;
    char                     ipbuf[INET_ADDRSTRLEN];
    in_port_t                port;

    if (getsockopt(c->fd, SOL_IP, SO_ORIGINAL_DST, &ss, &sslen) != 0) {
        ngx_log_error(NGX_LOG_DEBUG, c->log, ngx_errno,
                      "original_dst: getsockopt(SO_ORIGINAL_DST) failed");
        v->not_found = 1;
        return NGX_OK;
    }

    if (ss.ss_family != AF_INET) {
        /* IPv6 path (SOL_IPV6/IP6T_SO_ORIGINAL_DST) not handled in spike. */
        v->not_found = 1;
        return NGX_OK;
    }

    {
        struct sockaddr_in *sin = (struct sockaddr_in *) &ss;
        if (inet_ntop(AF_INET, &sin->sin_addr, ipbuf, sizeof(ipbuf)) == NULL) {
            v->not_found = 1;
            return NGX_OK;
        }
        port = ntohs(sin->sin_port);
    }

    buf = ngx_pnalloc(c->pool, INET_ADDRSTRLEN + 1 /*:*/ + 5 /*port*/);
    if (buf == NULL) {
        return NGX_ERROR;
    }

    v->len = ngx_sprintf(buf, "%s:%ui", ipbuf, (ngx_uint_t) port) - buf;
    v->data = buf;
    v->valid = 1;
    v->no_cacheable = 1;
    v->not_found = 0;

    return NGX_OK;
}
