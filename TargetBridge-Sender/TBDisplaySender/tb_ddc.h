// tb_ddc.h — DDC/CI luminance control for the external hardware display.
#ifndef TB_DDC_H
#define TB_DDC_H

#ifdef __cplusplus
extern "C" {
#endif

/// 1 when an external AVService (hardware display over HDMI/DP) is reachable.
int tb_ddc_available(void);

/// Set panel luminance as a percentage 0-100 of the panel's own range.
/// Returns 0 on success.
int tb_ddc_set_percent(int percent);

/// Read panel luminance as a percentage 0-100 of the panel's own range.
/// Returns -1 on transport failure, -2 if the panel gave no valid DDC reply.
int tb_ddc_get_percent(void);

#ifdef __cplusplus
}
#endif

#endif
