ARG HTCONDOR_SUBMIT_IMAGE=htcondor/submit:lts
FROM ${HTCONDOR_SUBMIT_IMAGE}

COPY condor_submit_bid /usr/local/bin/condor_submit_bid
RUN chmod 0755 /usr/local/bin/condor_submit_bid
