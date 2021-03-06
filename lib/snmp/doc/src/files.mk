#-*-makefile-*-   ; force emacs to enter makefile-mode

# %CopyrightBegin%
# 
# Copyright Ericsson AB 2001-2009. All Rights Reserved.
# 
# The contents of this file are subject to the Erlang Public License,
# Version 1.1, (the "License"); you may not use this file except in
# compliance with the License. You should have received a copy of the
# Erlang Public License along with this software. If not, it can be
# retrieved online at http://www.erlang.org/.
# 
# Software distributed under the License is distributed on an "AS IS"
# basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
# the License for the specific language governing rights and limitations
# under the License.
# 
# %CopyrightEnd%

XML_APPLICATION_FILES = \
        ref_man.xml

XML_APP_REF3_FILES = \
        snmp.xml

XML_COMP_REF3_FILES = \
        snmpc.xml

XML_MISC_REF3_FILES = \
        snmp_pdus.xml

XML_AGENT_REF3_FILES = \
	snmpa.xml \
	snmpa_conf.xml \
	snmpa_error_report.xml \
	snmpa_error.xml \
	snmpa_error_io.xml \
	snmpa_error_logger.xml \
	snmpa_local_db.xml \
	snmpa_mpd.xml \
	snmpa_network_interface.xml \
	snmpa_network_interface_filter.xml \
	snmpa_notification_delivery_info_receiver.xml \
	snmpa_notification_filter.xml \
	snmpa_supervisor.xml \
	snmp_community_mib.xml \
	snmp_framework_mib.xml \
	snmp_generic.xml \
	snmp_index.xml \
	snmp_notification_mib.xml \
	snmp_standard_mib.xml \
	snmp_target_mib.xml \
	snmp_user_based_sm_mib.xml \
	snmp_view_based_acm_mib.xml

XML_MANAGER_REF3_FILES = \
        snmpm.xml \
	snmpm_conf.xml \
        snmpm_mpd.xml \
	snmpm_network_interface.xml \
	snmpm_user.xml

XML_REF3_FILES = \
        $(XML_APP_REF3_FILES) \
        $(XML_COMP_REF3_FILES) \
        $(XML_MISC_REF3_FILES) \
        $(XML_AGENT_REF3_FILES) \
        $(XML_MANAGER_REF3_FILES)

XML_REF6_FILES = snmp_app.xml

XML_PART_FILES =  \
	part.xml \
	part_notes.xml \
	part_notes_history.xml

XML_CHAPTER_FILES = \
	snmp_intro.xml \
	snmp_agent_funct_descr.xml \
	snmp_manager_funct_descr.xml \
	snmp_mib_compiler.xml \
	snmp_config.xml \
	snmp_agent_config_files.xml \
	snmp_manager_config_files.xml \
	snmp_impl_example_agent.xml \
	snmp_impl_example_manager.xml \
	snmp_instr_functions.xml \
	snmp_def_instr_functions.xml \
	snmp_agent_netif.xml \
	snmp_manager_netif.xml \
	snmp_audit_trail_log.xml \
	snmp_advanced_agent.xml \
	snmp_app_a.xml \
	snmp_app_b.xml \
	notes.xml

BOOK_FILES = book.xml

XML_FILES = $(BOOK_FILES)         \
             $(XML_CHAPTER_FILES) \
             $(XML_PART_FILES)    \
             $(XML_REF6_FILES)    \
             $(XML_REF3_FILES)    \
             $(XML_APPLICATION_FILES)

GIF_FILES = book.gif \
	getnext1.gif \
	getnext2.gif \
	getnext3.gif \
	getnext4.gif \
	snmp_agent_netif_1.gif \
	snmp_manager_netif_1.gif \
	min_head.gif \
	note.gif \
	notes.gif \
	ref_man.gif \
	snmp-um-1-image-1.gif \
	snmp-um-1-image-2.gif \
	snmp-um-1-image-3.gif \
	snmp.gif \
	user_guide.gif \
	warning.gif \
	MIB_mechanism.gif

PS_FILES = getnext1.ps \
	getnext2.ps \
	getnext3.ps \
	getnext4.ps \
	snmp_agent_netif.ps \
	snmp-um-1-image-1.ps \
	snmp-um-1-image-2.ps \
	snmp-um-1-image-3.ps \
	snmp-um-1-image-8.ps \
	MIB_mechanism.ps

